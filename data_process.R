library('openxlsx')
library('data.table')
library('dplyr')
library('reshape2')
library('ggplot2')
library('lubridate')
library('gridExtra')

quarters <- function(x) {
  months(3 * x)
}

dir <- '/share/QA/Team/hui_zhang/Quant_Share/QF/CreditSpread/Transition/Consolidated'
file_path <- paste0(dir, '/data/ST Unsecured Issuance Spread Performance Testing - OCT 2025 fillna.xlsx')

read_bbg_data <- function(path, sheetname, startrow = 5, term_list = c(28, 60, 90, 180, 365, 398)) {
    # read the xlsx located at path, read in the sheetname, and set detect Dates to true, starting at startrow
    # convert the output into a data.table and store it in tmp_data
    tmp_data <- as.data.table(openxlsx::read.xlsx(path, 
                                                  sheet = sheetname,
                                                  startRow = startrow,
                                                  detectDates = T)) 
    # set the first column name to 'Date' and the rest are term_list
    names(tmp_data) <- c('Date', term_list)
    # melt the data.table by the term_list, and set the variable name to 'Term', and value name to Value
    tmp_data <- melt(tmp_data, id.vars = 'Date', variable.name = 'Term', value.name = 'Value')
    # mutate the table so that any value that is "#N/A" is set to NA
    tmp_data <- tmp_data %>% 
        mutate(Value = case_when(Value == "#N/A" ~ NA,
                                  TRUE ~ Value))
    # convert the Term column to numeric
    tmp_data$Term <- as.numeric(as.character(tmp_data$Term))
    # convert the Value column to numeric
    tmp_data$Value <- as.numeric(tmp_data$Value)
    # return the data.table
    return(data.table(tmp_data))
}

# R code first read in the short term unsecured issurance settled from Feb 2008 to May 2024.
# Products include bank notes, CD, Eurodollar deposit etc.  The original data includes tenor bucet
# that bucket the term of the product into <3M, 3M, 6M and 9M buckets.  Besides the trade level information
# such as settle date, maturity date, fixed or variable, for variable, index source and index spread
# are also included.  For the term of the contract, term libor rate, term sofr ratte, treasury rate, swap rate 3ML,
# and TermBSBY rate are calculated.  For basis information, basis1v3, FFv3Basis, SOFRv3basis are included.
# Several spreads are included, such as Spreadto3ML and SpreadtoTermBSBY.  Several spreads are calculated,
# such as sepreadtoTermTreasury and Yield.


## read in funding data
# the fill is located at file_path on a shet called ST Unsecured Data.  Read with the option detectDates = T
ST_Data <- data.table(openxlsx::read.xlsx(xlsxFile = file_path, 
                                                  sheet = 'ST Unsecured Data', 
                                                  detectDates = T))
# remove the . or ( or ) or % or # or / from the column names.  Use the escape syntax for the regex like \\.|\\(
names(ST_Data) <- gsub('\\.|\\(|\\)|\\%|\\#|\\/', '', names(ST_Data))
# change the column names '3mLSwapRate' to 'SwapRate3mL'
names(ST_Data)[names(ST_Data) == '3mLSwapRate'] <- 'SwapRate3mL'
# change the column names '1v3Basis' to 'Basis1v3'
names(ST_Data)[names(ST_Data) == '1v3Basis'] <- 'Basis1v3'
# mutate the ST_Data by looking at TenorBucket, if it is '&lt;3mo', set it to <3mo, otherwise, it's unchanged
ST_Data <- ST_Data %>% mutate(
    TenorBucket = case_when(TenorBucket == '&lt;3mo' ~ '<3mo',
                             TRUE ~ TenorBucket)
)

## remove redemptions by filtering to only include rows where Par is positive
ST_Data <- ST_Data %>% filter(Par > 0)

# next libor, BSBY, SOFR, T-Bill historical data for relevant terms are read in.
# LIBOR_Data is read from sheet 'BBG Term LIBOR', use the default for row to start, but specify the argument name for sheetname
LIBOR_Data <- read_bbg_data(file_path, sheetname = 'BBG Term LIBOR')
# BSBY_Data is from sheet 'BBG Term BSBY', use the default for row to start, but specify the argument name for sheetname
BSBY_Data <- read_bbg_data(file_path, sheetname = 'BBG Term BSBY')
# SOFR_Data is from sheet 'BBG Term SOFR', use the default for row to start, but specify the argument name for sheetname
SOFR_Data <- read_bbg_data(file_path, sheetname = 'BBG Term SOFR')
# TBill_Data is from sheet 'BBG Term T-Bill', use the default for row to start, but specify the argument name for sheetname, pass in the term list up to 398
TBill_Data <- read_bbg_data(file_path, sheetname = 'BBG T-Bill', term_list = c(28, 90, 180, 365, 398))
# Swap_Data is from sheet 'BBG Swap', use the default for row to start, but specify the argument name for sheetname, pass in the term list up to 730
Swap_Data <- read_bbg_data(file_path, sheetname = 'BBG Swap', term_list = c(90, 180, 270, 365, 730))
# Swap13_Data is from sheet 'BBG 1v3 Basis', use the default for row to start, but specify the argument name for sheetname, pass in the term list up to 730
Swap13_Data <- read_bbg_data(file_path, sheetname = 'BBG 1v3 Basis', term_list = c(90, 180, 270, 365, 730))
# FFTv3_Data is from sheet 'BBG FFv3 Basis', use the default for row to start, but specify the argument name for sheetname, pass in the term list up to 730
FFTv3_Data <- read_bbg_data(file_path, sheetname = 'BBG FFv3 Basis', term_list = c(90, 180, 270, 365, 730))
# SOFRv3_Data is from sheet 'BBG SOFRv3 Basis', use the default for row to start, but specify the argument name for sheetname, pass in the term list up to 730
SOFRv3_Data <- read_bbg_data(file_path, sheetname = 'BBG SOFRv3 Basis', term_list = c(90, 180, 270, 365, 730))

### fill missing data with QF rates
# read in 1Y, 2Y, 3Y CMT data. e.g, 1Y data is located at dir plus /data/CMT01Y.db.  Use fread to do this, and mutate the V1 column 
# to Date with format %m/%d/%Y and call it Date, and call the V2 colume Value_QF, and add a Term column with value 365,
# further, select only these three columns.  The CMT data for 2Y and 3Y are similar
CMT1Y <- fread(paste0(dir, '/data/CMT01Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), 
           Value_QF = V2,
           Term = 365) %>% 
    select(Date, Value_QF, Term)

CMT2Y <- fread(paste0(dir, '/data/CMT02Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), 
           Value_QF = V2,
           Term = 730) %>% 
    select(Date, Value_QF, Term)

    
CMT3Y <- fread(paste0(dir, '/data/CMT03Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), 
           Value_QF = V2,
           Term = 1095) %>% 
    select(Date, Value_QF, Term)

# CMT 1Y, 2Y, 3Y historical data are bound together into one dataset for period ranging from Aug. 25, 2004
# to July 18, 2024
# combine the CMT data into one data.table
CMT_Data <- rbindlist(list(CMT1Y, CMT2Y, CMT3Y))

# combines (merges) TBIL_Data with CMT1Y (including a modified version where Term is 398 instead of 365),
# based on matching Data and Term columns, keeping all rows from TBIL_Data
TBIL_Data <- merge(TBIL_Data, 
                   rbind(CMT1Y, CMT1Y %>% mutate(Term = 398)), 
                   by = c('Date', 'Term'), 
                   all.x = T)

# Modifies the TBIL_Data data frame by ensuring that the Value column has no missing values
# (replacing them with Value_QF if they exist) by coalesce Value and Value_QF
TBIL_Data <- TBIL_Data %>% 
    mutate(Value = coalesce(Value, Value_QF)) %>% 
    select(Date, Term, Value)

# set the SpreadtoTermTreasury_calc and Yield_calc columns to NA
ST_Data$SpreadtoTermTreasury_calc <- NA
ST_Data$Yield_calc <- NA

# set start.time to the current system time
start.time <- Sys.time()
# loop through each row of ST_Data
for (i in 1:nrow(ST_Data)) {
    # store SettleData, TermDays, RateType, IndexSource, IndexSpread and RateFixed values for the current row into local variables
    # like date.i etc
    date.i <- ST_Data$SettleDate[i]
    term.i <- ST_Data$TermDays[i]
    rate_type.i <- ST_Data$RateType[i]
    index.i <- ST_Data$IndexSource[i]
    index_spread.i <- ST_Data$IndexSpread[i]
    rate_fixed.i <- ST_Data$RateFixed[i]
    # get libor_data from the dataset LIBOR_Data where Date is equal to date.i
    libor_data <- LIBOR_Data[Date == date.i]

    # find where the value term.i fall wintin the Term column of libor-data and assigns this lower bound of the interval to
    # term_lb.i.  Use left.open = F option for the interval search
    term_lb.i <- libor_data$Term[findInterval(term.i, libor_data[['Term']], left.open = F)]
    # use the similar method to find the term_ub.i, but add 1 to the index of the index for the term_lb.i
    term_ub.i <- libor_data$Term[findInterval(term.i, libor_data[['Term']], left.open = F) + 1] 
    # store the libor value at the index corresponding to term_lb.i into libor_lb.i using the similar approach of finding interval for term.i in the Term column
    libor_lb.i <- libor_data$Value[findInterval(term.i, libor_data[['Term']], left.open = F)]
    # store the libor_ub.i value at the index corresponding to term_ub.i using the similar approach of finding interval for term.i in the Term column
    libor_ub.i <- libor_data$Value[findInterval(term.i, libor_data[['Term']], left.open = F) + 1]
    # calculate libor.i by interpolation using term.i between term_lb.i and term_ub.i
    libor.i <- libor_lb.i + (term.i - term_lb.i) * (libor_ub.i - libor_lb.i) / (term_ub.i - term_lb.i)

    # store the Swap_Data at the date.i value in local variable swap_data.i
    swap_data.i <- Swap_Data[Date == date.i]
    # using term.i to calculate the interpolated swap rate in the swap_data.i data set similar to the libor interpolation above
    term_lb.i <- swap_data.i$Term[findInterval(term.i, swap_data.i[['Term']], left.open = F)]
    term_ub.i <- swap_data.i$Term[findInterval(term.i, swap_data.i[['Term']], left.open = F) + 1]
    swap_lb.i <- swap_data.i$Value[findInterval(term.i, swap_data.i[['Term']], left.open = F)]
    swap_ub.i <- swap_data.i$Value[findInterval(term.i, swap_data.i[['Term']], left.open = F) + 1]
    swap.i <- swap_lb.i + (term.i - term_lb.i) * (swap_ub.i - swap_lb.i) / (term_ub.i - term_lb.i)

    # store the Swap13_Data at the date.i value in local variable swap13_data.i
    swap13_data.i <- Swap13_Data[Date == date.i]
    # using term.i to calculate the interpolated 1v3 basis and store the interpolated value in a local variable called swap13.i
    term_lb.i <- swap13_data.i$Term[findInterval(term.i, swap13_data.i[['Term']], left.open = F)]
    term_ub.i <- swap13_data.i$Term[findInterval(term.i, swap13_data.i[['Term']], left.open = F) + 1]
    swap13_lb.i <- swap13_data.i$Value[findInterval(term.i, swap13_data.i[['Term']], left.open = F)]
    swap13_ub.i <- swap13_data.i$Value[findInterval(term.i, swap13_data.i[['Term']], left.open = F) + 1]
    swap13.i <- swap13_lb.i + (term.i - term_lb.i) * (swap13_ub.i - swap13_lb.i) / (term_ub.i - term_lb.i)

    # store the FFTv3_Data at the date.i value in local variable fftv3_data.i
    fftv3_data.i <- FFTv3_Data[Date == date.i]
    # using term.i to calculate the interpolated value in a local variable fftv3.i
    term_lb.i <- fftv3_data.i$Term[findInterval(term.i, fftv3_data.i[['Term']], left.open = F)]
    term_ub.i <- fftv3_data.i$Term[findInterval(term.i, fftv3_data.i[['Term']], left.open = F) + 1]
    fftv3_lb.i <- fftv3_data.i$Value[findInterval(term.i, fftv3_data.i[['Term']], left.open = F)]
    fftv3_ub.i <- fftv3_data.i$Value[findInterval(term.i, fftv3_data.i[['Term']], left.open = F) + 1]
    fftv3.i <- fftv3_lb.i + (term.i - term_lb.i) * (fftv3_ub.i - fftv3_lb.i) / (term_ub.i - term_lb.i)

    # store the SOFRv3_Data at the date.i value in local variable sofrv3_data.i
    sofrv3_data.i <- SOFRv3_Data[Date == date.i]
    # using term.i to calculate the interpolated value in a local variable sofrv3.i
    term_lb.i <- sofrv3_data.i$Term[findInterval(term.i, sofrv3_data.i[['Term']], left.open = F)]
    term_ub.i <- sofrv3_data.i$Term[findInterval(term.i, sofrv3_data.i[['Term']], left.open = F) + 1]
    sofrv3_lb.i <- sofrv3_data.i$Value[findInterval(term.i, sofrv3_data.i[['Term']], left.open = F)]
    sofrv3_ub.i <- sofrv3_data.i$Value[findInterval(term.i, sofrv3_data.i[['Term']], left.open = F) + 1]
    sofrv3.i <- sofrv3_lb.i + (term.i - term_lb.i) * (sofrv3_ub.i - sofrv3_lb.i) / (term_ub.i - term_lb.i)

    # store the SOFR_Data at the date.i value in local variable sofr_data.i
    sofr_data.i <- SOFR_Data[Date == date.i]
    # using term.i to calculate the interpolated value in a local variable sofr.i
    term_lb.i <- sofr_data.i$Term[findInterval(term.i, sofr_data.i[['Term']], left.open = F)]
    term_ub.i <- sofr_data.i$Term[findInterval(term.i, sofr_data.i[['Term']], left.open = F) + 1]
    sofr_lb.i <- sofr_data.i$Value[findInterval(term.i, sofr_data.i[['Term']], left.open = F)]
    sofr_ub.i <- sofr_data.i$Value[findInterval(term.i, sofr_data.i[['Term']], left.open = F) + 1]
    sofr.i <- sofr_lb.i + (term.i - term_lb.i) * (sofr_ub.i - sofr_lb.i) / (term_ub.i - term_lb.i)

    # store the TBILL_Data at the date.i value in local variable tbill_data.i
    tbill_data.i <- TBIL_Data[Date == date.i]
    # using term.i to calculate the interpolated value in a local variable tbill.i
    term_lb.i <- tbill_data.i$Term[findInterval(term.i, tbill_data.i[['Term']], left.open = F)]
    term_ub.i <- tbill_data.i$Term[findInterval(term.i, tbill_data.i[['Term']], left.open = F) + 1]
    tbill_lb.i <- tbill_data.i$Value[findInterval(term.i, tbill_data.i[['Term']], left.open = F)]
    tbill_ub.i <- tbill_data.i$Value[findInterval(term.i, tbill_data.i[['Term']], left.open = F) + 1]
    tbill.i <- tbill_lb.i + (term.i - term_lb.i) * (tbill_ub.i - tbill_lb.i) / (term_ub.i - term_lb.i)

    # for fixed rate instrument, the spread to treasury is just the difference between the fixed rate and the interpolated
    # tbill rate by the term of the instrument. Calculate the local variable spread_treas.i and yield.i. The later is just the rate_fixed.i
    if (rate_type.i == 'Fixed') {
        spread_treas.i <- rate_fixed.i - tbill.i
        yield.i <- rate_fixed.i
    } else if (index.i == '3MOLIBOR') {
        # for floating rate indexed against 3 month libor, the rate is index_spread plus swap.  Calculate the local variable spread_treas.i
        # and yield.i
        spread_treas.i <- index_spread.i + swap.i - tbill.i
        yield.i <- index_spread.i + swap.i
    } else if (index.i == '1MOLIBOR') {
    # the spread to treasury and yield calculation for one month libor is similar to 3MOLIBOR
        spread_treas.i <- index_spread.i - swap13.i + swap.i - tbill.i
        yield.i <- index_spread.i - swap13.i + swap.i
    } else if (index.i == 'FEDL01') {
        # the spread to treasury and yield calculation for FEDL01 is similar to 1MOLIBOR, except the basis term is fftv3.i
        spread_treas.i <- index_spread.i - fftv3.i + swap.i - tbill.i
        yield.i <- index_spread.i - fftv3.i + swap.i
    } else if (index.i == 'SOFR') {
        # the spread to treasury and yield calculation for SOFR is similar to 3MOLIBOR
        spread_treas.i <- index_spread.i + sofr.i - tbill.i
        yield.i <- index_spread.i + sofr.i
    }
    # save the spread_treas.i in to the calculated spread to term treasury column in ST_Data
    ST_Data$SpreadtoTermTreasury_calc[i] <- spread_treas.i
    # save the yield.i in to the calculated yield column in ST_Data
    ST_Data$Yield_calc[i] <- yield.i

    print(i)
}

# record the end time
end.time <- Sys.time()
# calculate the time difference
time.taken <- end.time - start.time

# save the ST_Data to a csv file using write.csv function with row.names turned off
write.csv(ST_Data, paste0(dir, '/data/ST_Data.csv'), row.names = F)

# read the ST_Data back in using fread
ST_Data <- fread(paste0(dir, '/data/ST_Data.csv'))

# filter out the rows of ST_Data where CUSIP is '06054R6M9 or is.na
ST_Data <- ST_Data %>% filter(CUSIP == '06054R6M9' | is.na(CUSIP))

# pip the ST_Data to group by SettleDate and TenorBucket and summarise the calculated spread to term treasury and yield  by mean value weighted by Par value,
# also summarize the number of rows as NumTransaction, pipe the summaries to a data.table and store the result in ST_Data_Agg
ST_Data_Agg <- ST_Data %>% 
    group_by(SettleDate, TenorBucket) %>% 
    summarise(SpreadtoTermTreasury = weighted.mean(SpreadtoTermTreasury_calc, Par), 
              Yield = weighted.mean(Yield_calc, Par), 
              NumTransaction = n()) %>% 
    data.table()

# use dcast to transform LIBOR_Data from a long format with separate rows for each Date and Term pair
# to a wide format with each Date has its own row and each unique Term becomes a column,
# and the Value column contains the corresponding values
LIBOR_Data_revise <- dcast(LIBOR_Data, Date ~ Term, value.var = 'Value')

# set the first column name of LIBOR_Data_revise to SettleDate and add a 'x' to the front of the columne names of columns 2 to 7 
# create a c() to do this in one statement and use the paste0 to do the string manipulation
# this turn column names into SettleDate, x28, x60, x90, x180, x365, x398
names(LIBOR_Data_revise) <- c('SettleDate', paste0('x', names(LIBOR_Data_revise)[2:7]))

# filter LIBOR_Data_revise to only include rows where SettleDate is earlier and including 2023-06-30, and create columns
# xlt3mo using the values of x28, x3mo using the values of x90, x6mo using the values of x180, x9mo using the average of x180 and x365,
# and x1yr using the average of x365.  Select only the SettleDate, xlt3mo, x3mo, x6mo, x9mo, x1yr columns
LIBOR_Data_revise <- LIBOR_Data_revise %>% 
    filter(SettleDate <= '2023-06-30') %>% 
    mutate(xlt3mo = x28, x3mo = x90, x6mo = x180, x9mo = (x180 + x365) / 2, x1yr = x365) %>% 
    select(SettleDate, xlt3mo, x3mo, x6mo, x9mo, x1yr)

# metla the LIBOR_Data_revise data by the SettleDate as id, and TenorBucket as the variable, which currently in the database, we
# have xlt3mo, x3mo, x6mo, x9mo, x1yr columns, and a value column that is TermLIBOR values
LIBOR_Data_revise <- melt(LIBOR_Data_revise, id.vars = 'SettleDate', variable.name = 'TenorBucket', value.name = 'TermLIBOR')

# remove all the x's in the TenorBucket column
LIBOR_Data_revise$TenorBucket <- gsub('x', '', LIBOR_Data_revise$TenorBucket)

# change all the lt3mo in the TenorBucket column to <3mo
LIBOR_Data_revise$TenorBucket <- gsub('lt3mo', '<3mo', LIBOR_Data_revise$TenorBucket)

# use dcast to transform TBIL_Data from a long format with separate rows for each Date and Term pair
# to a wide format with each Date has its own row and each unique Term becomes a column,
# and the Value column contains the corresponding values
TBIL_Data_revise <- dcast(TBIL_Data, Date ~ Term, value.var = 'Value')

# set the first column name of TBIL_Data_revise to SettleDate and add a 'x' to the front of the columne names of columns 2 to 6 
# create a c() to do this in one statement and use the paste0 to do the string manipulation
# this turn column names into SettleDate, x28, x90, x180, x365
names(TBIL_Data_revise) <- c('SettleDate', paste0('x', names(TBIL_Data_revise)[2:6]))

# mutate TBIL_Data_revise to create a new column xlt3mo that is x28, a new column x3mo that is x90, a new column x6mo that is x180,
# a new column x9mo that is the average of x180 and x365, and a new column x1yr that is x365, and select only the SettleDate, 
# xlt3mo, x3mo, x6mo, x9mo, x1yr columns
TBIL_Data_revise <- TBIL_Data_revise %>% 
    mutate(xlt3mo = x28, x3mo = x90, x6mo = x180, x9mo = (x180 + x365) / 2, x1yr = x365) %>% 
    select(SettleDate, xlt3mo, x3mo, x6mo, x9mo, x1yr)

# melt the TBIL_Data_revise data by the SettleDate as id, and TenorBucket as the variable, which currently in the database, we
# have xlt3mo, x3mo, x6mo, x9mo, x1yr columns, and a value column that is TermUST values
TBIL_Data_revise <- melt(TBIL_Data_revise, id.vars = 'SettleDate', variable.name = 'TenorBucket', value.name = 'TermUST')

# remove all the x's in the TenorBucket column
TBIL_Data_revise$TenorBucket <- gsub('x', '', TBIL_Data_revise$TenorBucket)
# change all the lt3mo in the TenorBucket column to <3mo
TBIL_Data_revise$TenorBucket <- gsub('lt3mo', '<3mo', TBIL_Data_revise$TenorBucket)

# add TermLIBOR and TermUST to the ST_Data_agg table that currently has SettleDate, TenorBucket, SpreadtoTreasury, Yield and NumTransaction columns
# implement this by first merging the ST_Data_Agg and LIBOR_Data_revise tables by SettleDate and TenorBucket, and then merging the result
# with the TBIL_Data_revise table by SettleDate and TenorBucket
ST_Data_Agg <- merge(ST_Data_Agg, LIBOR_Data_revise, by = c('SettleDate', 'TenorBucket'), all.x = T)
ST_Data_Agg <- merge(ST_Data_Agg, TBIL_Data_revise, by = c('SettleDate', 'TenorBucket'), all.x = T)

# mutate ST_Data_Agg to create a new column LIBORtoTreasury by taking the difference between TermLIBOR and TermUST,
# and select only the SettleDate, TenorBucket, SpreadtoTreasury, Yield, TermLIBOR, NumTransaction, LIBORtoTreasury columns
ST_Data_Agg <- ST_Data_Agg %>% 
    mutate(LIBORtoTreasury = TermLIBOR - TermUST) %>% 
    select(SettleDate, TenorBucket, SpreadtoTermTreasury, Yield, TermLIBOR, NumTransaction, LIBORtoTreasury)

# read in C1A2_Data table from the data directory a xlsx file called /data/c1a2.xlsx, set detectDates = T.  Use openxlsx
# to implement this and cast the result to a data.table
C1A2_Data <- data.table(openxlsx::read.xlsx(xlsxFile = paste0(dir, '/data/c1a2.xlsx'), detectDates = T))

# set the column names of C1A2_Data by removing all the . or (,),#,/  from the column names. 
# Use escape syntax for the regex, like \\.|\\(|\\)|\\)|\\%|\\#|\\/
names(C1A2_Data) <- gsub('\\.|\\(|\\)|\\%|\\#|\\/', '', names(C1A2_Data))

# select only the Date, EffectiveYield, MaturityWAL from the C1A2_Data table
C1A2_Data <- C1A2_Data %>% select(Date, EffectiveYield, MaturityWAL)

# read in the TBond_Data from /data/bbg_tsy.csv using fread
TBond_Data <- fread(paste0(dir, '/data/bbg_tsy.csv'))

# reset the column names to Date, UST1M, UST3M, UST6M, UST1Y, UST2Y, UST3Y.
names(TBond_Data) <- c('Date', 'UST1M', 'UST3M', 'UST6M', 'UST1Y', 'UST2Y', 'UST3Y')

# read in /data/CMT01Y.db using fread and mutate the V1 column to be the Date column and the V2 column to be the CMT1Y column. Do these two operation in one line.
# when we caste V1 to Date, use the format %m/%d/%Y.  Select only the Date and CMT1Y columns.  Store the result in CMT1Y
CMT1Y <- fread(paste0(dir, '/data/CMT01Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), CMT1Y = V2) %>% 
    select(Date, CMT1Y)
# also read in CMT2Y and CMT3Y in the same way
CMT2Y <- fread(paste0(dir, '/data/CMT02Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), CMT2Y = V2) %>% 
    select(Date, CMT2Y)
CMT3Y <- fread(paste0(dir, '/data/CMT03Y.db')) %>% 
    mutate(Date = as.Date(V1, '%m/%d/%Y'), CMT3Y = V2) %>% 
    select(Date, CMT3Y)

# combine CMT1Y, 2Y and 3Y into a single data frome called CMT_Data by merging by Date column.
# implement this by using Reduce and applying a function that takes two data frames and merges them by Date column.
CMT_Data <- Reduce(function(x, y) merge(x, y, by = 'Date'), list(CMT1Y, CMT2Y, CMT3Y))

# update TBond_Data by first mutate the Date column by casting it to Date and using the format %m/%d/%Y.  Then merge the result with CMT_Data 
# left joining on the Date column.  And then filling all missing data in UST1Y column with the value in CMT1Y column by coalesce function.
# do the same for UST2Y and UST 3Y on the same line, finally select only the Date, UST1Y, UST2Y, UST3Y columns.
TBond_Data <- TBond_Data %>%
    mutate(Date = as.Date(Date, '%m/%d/%Y')) %>% 
    left_join(CMT_Data, by = 'Date') %>% 
    mutate(UST1Y = coalesce(UST1Y, CMT1Y), UST2Y = coalesce(UST2Y, CMT2Y), UST3Y = coalesce(UST3Y, CMT3Y)) %>% 
    select(Date, UST1Y, UST2Y, UST3Y)

# merge C1A2_Data and TBond_Data by Date column
C1A2_Data <- merge(C1A2_Data, TBond_Data, by = 'Date', all.x = T)

# Mutate the C1A2_Data by adding a new column C1A2SpreadtoTreas based on the difference between EffectiveYield
# and a value calculated conditional on MaturityWAL's value.  When MaturityWAL is less than 2, the value is
# the interpolated value obtained by interpolating between the points (1, UST1Y) and (2, UST2Y) using MaturityWAL,
# otherwise, the value is the interpolated value obtained by interpolating between the points (2, UST2Y) and (3, UST3Y) using MaturityWAL.
# Then the C1A2_Data is mutated by rename the Date to SettleDate, finally select only the SettleDate, C1A2SpreadtoTreas and EffectiveYield
C1A2_Data <- C1A2_Data %>% 
    mutate(C1A2SpreadtoTreas = EffectiveYield - 
           case_when( MaturityWAL < 2 ~ UST1Y + (MaturityWAL - 1) * (UST2Y - UST1Y) / (2 - 1),
                      TRUE ~ UST2Y + (MaturityWAL - 2) * (UST3Y - UST2Y) / (3 - 2))) %>% 
    mutate(SettleDate = Date) %>% 
    select(SettleDate, C1A2SpreadtoTreas, EffectiveYield)

# use write.csv to save to C1A2_Data.csv, disable row.names
write.csv(C1A2_Data, paste0(dir, '/data/C1A2_Data.csv'), row.names = F)

# merge ST_Data_Agg and C1A2_Data by SettleDate column
ST_Data_Agg <- merge(ST_Data_Agg, C1A2_Data, by = 'SettleDate', all.x = T)

# write.csv to save to ST_Data_Agg.csv, disable row.names
write.csv(ST_Data_Agg, paste0(dir, '/data/ST_Data_Agg.csv'), row.names = F)

# Take the ST_Data and group it by SettleDatee, TenorBucket, and Product, 
# then pipe the grouped dataset to summarize and calculate SpreadtoTreasury as weighted mean of SpreadtoTermTreasury weighted by Par,
# and calculate NumTransaction as number of rows 
# case this result to a data.table and store the result in ST_Data_Agg_check
ST_Data_Agg_check <- ST_Data %>% 
    group_by(SettleDate, TenorBucket, Product) %>% 
    summarise(SpreadtoTreasury = weighted.mean(SpreadtoTermTreasury_calc, Par), 
              NumTransaction = n()) %>% 
    data.table()

# merge ST_Data_Agg_check and C1A2_Data by SettleDate column, thereby incorporating the C1A2SpreadtoTreas and EffectiveYield columns into ST_Data_Agg_check
ST_Data_Agg_check <- merge(ST_Data_Agg_check, C1A2_Data, by = 'SettleDate', all.x = T)

# merge ST_Data_Agg_check and LIBOR_Data_revise by SettleDate and TenorBucket, thereby incorporating the TermLIBOR column into ST_Data_Agg_check
ST_Data_Agg_check <- merge(ST_Data_Agg_check, LIBOR_Data_revise, by = c('SettleDate', 'TenorBucket'), all.x = T)

# merge ST_Data_Agg_check and TBIL_Data_revise by SettleDate and TenorBucket, thereby incorporating the TermUST column into ST_Data_Agg_check
ST_Data_Agg_check <- merge(ST_Data_Agg_check, TBIL_Data_revise, by = c('SettleDate', 'TenorBucket'), all.x = T)

# mutate ST_Data_Agg_check to create a new column LIBORtoTreasury by taking the difference between TermLIBOR and TermUST,
# and select only the SettleDate, TenorBucket, Product, SpreadtoTreasury, NumTransaction, LIBORtoTreasury, C1A2SpreadtoTreas columns
ST_Data_Agg_check <- ST_Data_Agg_check %>% 
    mutate(LIBORtoTreasury = TermLIBOR - TermUST) %>%
    select(SettleDate, TenorBucket, Product, SpreadtoTreasury, NumTransaction, LIBORtoTreasury, C1A2SpreadtoTreas)

