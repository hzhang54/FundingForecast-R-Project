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

class CDSMarketDataFunctor(CDSFunctor):
    @property
    def create_cashflow_schedule(self):
        return make_cashflow_schedule(self._input_params) # TODO: to implement

class CDSTradeFunctor(CDSFunctor):
    @property
    def create_cashflow_schedule(self):
        return make_trade_cashflow_schedule(self._input_params) # TODO: To implement