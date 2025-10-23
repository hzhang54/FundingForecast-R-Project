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
