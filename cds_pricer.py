import logging
import pandas as pd

from . import cds_functor_factory as cff


logger = locals().getLogger(__name__)

def build_pricer(
    input_params,
    run_date,
    coupon,
    quote,
    quote_type,
    ticker,
    notional_delta,
    # notional,
    # amortization_schedule_inverse
    quarter,
    scenario,
    amortization_scheule,
):
    """ Build the pricer and reference data for the current run_date and input_params """
    input_params['md_curvedate'] = run_date
    input_params['Coupon'] = coupon
    input_params['cds_spread'] = quote
    input_params['Quotes_type'] = quote_type
    input_params['Ticker'] = ticker

    pricingParams = input_params['pricingParams']

    ycg = cff.YieldCurveGroup(input_params, run_date, quarter=quarter, scenario=scenario)()

    market_data = cff.CDSMarketDataFunctor(
        input_params=input_params,
        run_date=run_date,
        functor_name='Credit.CreditMarketData',
        yield_curve_group=ycg,
        components = ['CDSCreditCurves', 'ConfigOptions', 'YieldCurves'],
        methods = ['CDSCreditCurves', 'ConfigOptions', 'YieldCurves'],
    )()

    instrument = cff.CDSTradeFunctor(
        input_params=input_params,
        run_date=run_date,
        functor_name='Credit.CDSTrade',
        yield_curve_group=ycg,
        components=['Basket', 'Instrument', 'TradeDate', 'BuySell', 'Quantity', 'YieldCurve'],
        methods=['Basket', 'Instrument',  'YieldCurve', 'TradeDate'],
    )()

    # TODO: Currently the functor does not make this easy to change
    [d.update({'Notional': max(d['Notional'] - notional_delta, 0.0)}) for d in amortization_scheule]
    instrument['Instrument']['PremiumLeg']['Cashflows'] = amortization_scheule
    market_data["CDSCreditCurves"][0]['CreditCurve']['CalibInsts'][0]['Instrument']['PremiumLeg'].update(
        {'Cashflows': amortization_scheule}
    )

    # TODO: <Correct the Node dates issue>
    yc = instrument['YieldCurve']['YieldCurve'].clone()

    terms = (1, 3, 6, 12, 24, 36)
    yc['Curves'][0][Curve] = yc['Curves'][0][Curve].curry({'CurveDate': run_date})
    for i, term in enumerate(terms):
        term_date = run_date + relativedelta(months=term)
        yc['Curves'][0][Curve]['ExtraParams']['SolverSettings']['SmoothCurveSettings']['IndexSettings']['NodeDates'][i] = term_date
    
    instrument['YieldCurve']['YieldCurve'] = yc

    market_data['YieldCurves'][0]['YieldCurve'] = yc
    ccf = market_data['CDSCreditCurves'][0]['CreditCurve'].clone()
    ccf = ccf.curry({'YieldCurve': yc})
    market_data['CDSCreditCurves'][0]['CreditCurve'] = ccf

    pricing_functor = gda.Functor(
        'Credit.CDSPrice',
        {
            'Trade': instrument,
            'MarketData': market_data,
            'PricingParams': pricingParams,
        }
    )
    return pricing_functor

class CdsPricer:
    def __init__(
        self,
        subtranche,
        ticker,
        notional,
        run_date,
        quote,
        quote_type,
        coupon,
        amortization_scheule,
        notional_delta,
        # amortization_schedule_inverse,
        requests,
        pricing_config,
        run_config,
        input_params,
    ):
        """Wrapper for the GDA pricing of CDS trades
        :param subtranche: The subtranche to price
        :param ticker: The ticker for subtranche
        :param notional: The notional for the subtranche for the run date.
        :param run_date: The Asof date for the trade pricing calculations.
        :param quote: The Value of the spread.  For 'DEFAULTSWAP' this is in percent not bps.
        :param quote_type: The type of quote.  Should be 'DEFAULTSWAP'.
        :param coupon: Premium coupon payment rate.
        :param amortization_scheule: The amortization curve provided to the pricer.
        :param amortization_schedule_inverse: The inverse of the amortization at the run date, to avoid double counting.
        :param requests: Pricing requests to execute when pricing.
        :param pricing_config: 
        :param run_config:
        """
        self.notional = notional
        self.subtranche = subtranche
        self.ticker = ticker
        self.requests = requests
        self.quote = quote
        self.quote_type = quote_type
        self.coupon = coupon
        self.amortization_scheule = amortization_scheule
        self.notional_delta = notional_delta
        self.run_config = run_config
        self.pricing_config = pricing_config
        self.run_date = run_date
        self.input_params = input_params

        # Setup the pricer
        self.pricer = self._build_pricer()

    def _build_pricer(self) -> gda.Functor:
        """Build the pricer functor for the current run_date and input_params"""
        pricer = build_pricer(
            self.input_params,
            self.run_date,
            self.coupon,
            self.quote,
            self.quote_type,
            self.ticker,
            self.notional_delta,
            # self.notional,
            # self.amortization_schedule_inverse,
            quarter = self.run_config['quarter'],
            scenario = self.run_config['current_scenario'],
            amortization_scheule = self.amortization_scheule,
        )
        return pricer

    def price(self) -> pd.DataFrame:
        """Price the current subtranche"""
        logger.info(f'Pricing subtranche {self.subtranche} for {self.run_date}')
        try:
            hde_result = self.pricer.apply(self.requests)
            result = {k: v for k, v in hde_result.items()}
        except gda.Exception as e:
            if e.message.find('A calibration instrument must have non-zero notional for at least one leg.') > -1:
                # The notional of the tranche has amortized to zero, there is no PV
                result = {request: 0.0 for request in self.requests}
            else:
                raise ValueError(e.message)

        result['SubTranche'] = self.subtranche
        result['ticker'] = self.ticker
        result['run_date'] = self.run_date
        result['notional'] = self.notional
        result['notional_delta'] = self.notional_delta
        
        return result

        