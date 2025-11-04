from abc import ABC, abstractmethod
import datetime
from auto_srt_helpers import (
    make_cashflow_schedule,
    make_trade_cashflow_schedule,
)

class YieldCurveGroup:
    '''
    Create the yield curve functor used by the credit cds pricer functor. Class used by both components of Credit.CDSPricer, marketdata and trade
    '''
    def __init__(self, input_params, ref_date, quarter='2025Q1', scenario='BACBL'): # index_insts,
        self._input_params = input_params
        self._ref_date = ref_date
        # self._index_insts = index_insts # TODO: Implement IndexInsts
        self.data_source = DataGetter(quarter,scenario)

    def __call__(self):
        return self.get_yield_curve()

    @property
    def input_params(self):
        return self._input_params

    @property
    def ref_date(self):
        return self._ref_date

    def get_yield_curve(self):
        input_params = self._input_params
        return gda.Functor(
            'Curve.YieldCurveGroup',
            {
                'Curves': self.create_curves_list(),
                'FunctorType': 'YieldCurveGroup',
                'PackageName': 'Curve',
                'Prices': gda.Missing, 
                'Resets': gda.Missing,
                'ResetProperties': {
                    'AllowMissingResetsForHistoricPayments': input_params['AllowMissingResetsForHistoricPayments'],
                    'ForceTodayLive': input_params['ForceTodayLive'],
                    'ImplicitUse': input_params['ImplicitUse'],
                },
                'StaticData': gda.Missing,
                'Version': 2,
            },
        )
    def create_curves_list(self, all_tenors=['1M', '3M', '6M', '12M', '1Y', '2Y', '3Y']):
        input_params = self._input_params
        # index_insts = self._index_insts # TODO: To implement
        index_insts = self.create_index_insts()
        args = {
            'BasisMethod': input_params['BasisMethod'],
            'Currency': input_params['Currency'],
            'CurveDate': input_params['md_curvedate'],
            'Cutover': input_params['Cutover'],
            'ExtraParams': self.get_extraparams(),
            'IndexInsts': index_insts,
            'FxQuoteType': input_params['FxQuoteType'],
            'Index': input_params['Index'],
            'Fx': 1.0,
            'Insts': None,
            'Interpolator': input_params['Interpolator'],
            'ExtrapolationType': input_params['ExtrapolationType'],
            'SwapInterpolator': input_params['SwapInterpolator'],
        }

        build = False
        while build is False:
            yield_curve = gda.Functor(
                'Curve.YieldCurve',
                args,
            )
            try:
                yield_curve.apply('ZeroCurve')['ZeroCurve']
                build = True
            except gda.Exception:
                if not index_insts:
                    raise ValueError('No index insts provided')
                for i in index_insts:
                    if i['Term'] == all_tenors[-1]:
                        index_insts.pop(index_insts.index(i))
                        all_tenors.pop(-1)
        return [
            {
                'Curve': gda.Functor('Curve.YieldCurve', args),
                'Type': input_params['YieldCurveType'],
            }
        ]

    def create_index_insts(self, all_tenors=['1M', '3M', '6M', '12M', '1Y', '2Y', '3Y']):
        input_params = self._input_params
        index_insts_m, index_insts_y = [], []
        index_data = self.data_source.macro_data.inMemCopy().restrict(
            lambda x: input_params['Currency'] in x, 'VARIABLENAME'
        )
        index_data = index_data.restrict(
            lambda x, y: any((_str in x for _str in ['OIS', 'CMPD'])) and end_quarter_date(y) == self.ref_date,
            ['VARIABLENAME', 'PERIODLOOKUP'],
        )
        for (_, _, _, name, rate) in index_data:
            _, term = get_index_name_and_tenor(name)
            if term in all_tenors:
                if 'M' in term:
                    index_insts_m.append(dict(Type=get_rate_type(term), Term=term, Rate=rate))
                else:
                    index_insts_y.append(dict(Type=get_rate_type(term), Term=term, Rate=rate))

        index_insts = [
            *sorted(index_insts_m, key=lambda x: int(x['Term'][:-1])),
            *sorted(index_insts_y, key=lambda x: int(x['Term'][:-1])),
        ]

        return index_insts

    def get_extraparams(self):
        # return a dictionary, with the value for each key retried from the value in self._input_params.
        # for example 'ClearZeroDeltaPanels' is from self._input_params['ClearZeroDeltaPanels']
        # do this for FirstIndexInterpolator, FirstIndexSpreadMethod, FundingTurnBlocks,
        # IgnoreExpiringFutures, Implyconvexity, IndexInstsName, IndexSpreadMethodCutOver,
        # IndexTurnBlocks, InterpCutover, SolverSettings
        return {
            'ClearZeroDeltaPanels': self._input_params['ClearZeroDeltaPanels'],
            'FirstIndexInterpolator': self._input_params['FirstIndexInterpolator'],
            'FirstIndexSpreadMethod': self._input_params['FirstIndexSpreadMethod'],
            'FundingTurnBlocks': self._input_params['FundingTurnBlocks'],
            'IgnoreExpiringFutures': self._input_params['IgnoreExpiringFutures'],
            'Implyconvexity': self._input_params['Implyconvexity'],
            'IndexInstsName': self._input_params['IndexInstsName'],
            'IndexSpreadMethodCutOver': self._input_params['IndexSpreadMethodCutOver'],
            'IndexTurnBlocks': self._input_params['IndexTurnBlocks'],
            'InterpCutover': self._input_params['InterpCutover'],
            'SolverSettings': self._input_params['SolverSettings'],
        }

class CDSFunctor(ABC):
    def __init__(
        self,
        input_params: dict,
        run_date: datetime.date,
        functor_name: str,
        yield_curve_group: YieldCurveGroup,
        components=[],
        methods=[],
    ):
        self._input_params = input_params
        self._tradedate = run_date
        self._functor_name = functor_name
        self._yield_curve_group = yield_curve_group
        self._components = components
        self._methods = methods

    def __call__(self):
        return gda.Functor(
            self.functor_name,
            {
                component: getattr(self, 'get_' + component.lower())()
                if self.get_call_type(component, self.methods) == object
                else self._input_params[component]
                for component in self.components
            },
        )

    @classmethod
    def get_call_type(cls, component, methods):
        return object if component in methods else str

    @abstractmethod
    def get_instrument(self):
        pass

    @property
    def get_trade_name(self):
        # a string formed by . separated substrings.  First substrings is the value of self._input_params with the key Ticker,
        # followed by the value of the key Subordination, then RestructuringClause, then Currency
        return (
            f"{self._input_params['Ticker']}."
            f"{self._input_params['Subordination']}."
            f"{self._input_params['RestructuringClause']}."
            f"{self._input_params['Currency']}.MNTH"
        )
    
    @property
    def input_params(self):
        return self._input_params

    @property
    def functor_name(self):
        return self._functor_name

    @property
    def tradedate(self):
        return self._tradedate

    @property
    def yield_curve_group(self):
        return self._yield_curve_group

    @property
    def components(self):
        return self._components

    @components.setter
    def components(self, components):
        self._components = components
    
    @property
    def methods(self):
        return self._methods

#methods.setter
    @methods.setter
    def methods(self, methods):
        self._methods = methods

class CDSMarketDataFunctor(CDSFunctor):
    @property
    def create_cashflow_schedule(self):
        return make_cashflow_schedule(self._input_params) # TODO: to implement
    
    def get_instrument(self):
        # return a gda.Function with 'Credit.CDSInst' as the first arg
        # and a dictionary as the second arg.  The dict with key PremiumLeg is a dict with a key Cashflows, and value given by self.create_cashflow_schedule
        # and the ProtectionLeg is an empty dict
        return gda.Functor(
            'Credit.CDSInst',
            {
                'PremiumLeg': {
                    'Cashflows': self.create_cashflow_schedule,
                },
                'ProtectionLeg': {},
            },
        )
    
    def get_yield_curve(self):
        # return a dict with the key Name has the value that is a string starting with YCG. followed by the value of the Currency key in self._input_params
        # and the key YieldCurve has the value that is the result of calling self._yield_curve_group
        return {
            'Name': f'YCG.{self._input_params["Currency"]}',
            'YieldCurve': self._yield_curve_group,
        }
    
    def get_config_options(self):
        return self._input_params['ConfigOptions']

    
    def get_cdscreditcurves(self):
        # return an array with a dict inside, the CreditCurve key is created by calling self.create_credit_curve
        # passing in _tradedate, and the key Name has the value from self.get_trade_name
        return [
            {
                'CreditCurve': self.create_credit_curve(self._tradedate),
                'Name': f'{self.get_trade_name}',
            }
        ]

    def create_credit_curve(self, run_date):
        # return a gda.Function with 'Credit.CreditCurve' as the first arg
        # and a dictionary as the second arg.  The dict with key CalibInsts is an array with a dict inside
        # the key FixedRate has value gotten from self._input_params with the key Coupon,
        # the key Quote has value gotten from self._input_params with the key cds_spread
        # the key Type has value gotten from self._input_params with the key Quotes_type
        # the key Instrument has value gotten from self.get_instrument()
        return gda.Functor(
            'Credit.CreditCurve',
            {
                'CalibInsts': [
                    {
                        'FixedRate': self._input_params['Coupon'],
                        'Quote': self._input_params['cds_spread'],
                        'Type': self._input_params['Quotes_type'],
                        'Instrument': self.get_instrument(),
                    }
                ],
                # the key calibOptions has a value that is a dict
                # Each key in this dict is gotten from self._input_params with the key of the same name
                # the keys are AllowIncompleteCurve, ExcludeMaturedInsts, FloorHazardRates, FloorProbabilities, InterpConv, RelAcc, RemoveBondCaches
                # SmoothCurveCalibrationParams, UseISDASettleDateCalib, UseLegacyInfiniteSpreadCheck,
                # UseMaxPossibleQuote, useSmoothCurveCalibration
                'calibOptions': {
                    'AllowIncompleteCurve': self._input_params['AllowIncompleteCurve'],
                    'ExcludeMaturedInsts': self._input_params['ExcludeMaturedInsts'],
                    'FloorHazardRates': self._input_params['FloorHazardRates'],
                    'FloorProbabilities': self._input_params['FloorProbabilities'],
                    'InterpConv': self._input_params['InterpConv'],
                    'RelAcc': self._input_params['RelAcc'],
                    'RemoveBondCaches': self._input_params['RemoveBondCaches'],
                    'SmoothCurveCalibrationParams': self._input_params['SmoothCurveCalibrationParams'],
                    'UseISDASettleDateCalib': self._input_params['UseISDASettleDateCalib'],
                    'UseLegacyInfiniteSpreadCheck': self._input_params['UseLegacyInfiniteSpreadCheck'],
                    'UseMaxPossibleQuote': self._input_params['UseMaxPossibleQuote'],
                    'useSmoothCurveCalibration': self._input_params['useSmoothCurveCalibration'],
                },
                # the value for CreditDetails is similar to the above, but the keys are
                # Currency, RestructuringClause, Subordination, Ticker
                'CreditDetails': {
                    'Currency': self._input_params['Currency'],
                    'RestructuringClause': self._input_params['RestructuringClause'],
                    'Subordination': self._input_params['Subordination'],
                    'Ticker': self._input_params['Ticker'],
                },
                # the value for the key FundingID is from _input_params with key of the same name
                'FundingID': self._input_params['FundingID'],
                # similarly for Recovery
                'Recovery': self._input_params['constant_recovery'],
                'YieldCurve': self._yield_curve_group,
            },
        )
            
class CDSTradeFunctor(CDSFunctor):
    @property
    def create_cashflow_schedule(self):
        return make_trade_cashflow_schedule(self._input_params) # TODO: To implement

    # get_instrument function return a gda.Functor with the string Credit.CDSInst as the first arg,
    # and a dictionary as the second arg. The keys of this dict are AccruedInDefault, ExtraAccDay,
    # PremiumLeg and ProtectionLeg
    def get_instrument(self):
        return gda.Functor(
            'Credit.CDSInst',
            {
                'AccruedInDefault': self._input_params['AccruedInDefault'],
                'ExtraAccDay': self._input_params['ExtraAccDay'],
                'PremiumLeg': {
                    'Cashflows': self.create_cashflow_schedule,
                },
                'ProtectionLeg': {},
            },
        )
    
    def get_basket(self):
        '''
        Basket can be either a list or a name.  A dedicated method is implemented to allow easy extension in the future
        '''
        # return a gda.Function with the string Credit.CreditBasket, and a dict with the key Basket have the value
        # that is a dict with the key CreditCurve with value from self.get_trade_name
        return gda.Functor(
            'Credit.CreditBasket',
            {
                'Basket': {
                    'CreditCurve': self.get_trade_name,
                }
            },
        )
    # get_yieldcurve function return a dict with the key FundingId and YieldCurve
    def get_yieldcurve(self):
        return {
            'FundingId': self._input_params['FundingID'],
            'YieldCurve': self._yield_curve_group
        }

    def get_tradedate(self):
        return self._tradedate