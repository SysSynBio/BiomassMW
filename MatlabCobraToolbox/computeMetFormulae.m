function [model,metCompute,ele,metEle,rxnBal,S_fill,solInfo,N,LP] = computeMetFormulae(model,metKnown,rxns,metFill,findCM,nameCM,varargin)
% Compute the chemical formulas of the unknown metabolites using a set of metabolites with known formulae and a set of reactions.
% To include charge balance in the computation, simply in all formulas, add e.g. 'Charge2' for charge +2 or 'Charge-1' for charge -1.
% The minimum conflict is found by allowing filling up by metFill (e.g. H+) in the reaction stoichiometry
%
% USAGE:
%    [model,metCompute,ele,metEle,rxnBal,S_fill,solInfo,N,LP] = computeMetFormulae(model,metKnown,rxns,metFill,findCM,nameCM,params)
%
% INPUT:
%    model:          COBRA model
%
% OPTIONAL INPUTS:
%    metKnown:       Known metabolites (cell array of strings or vector of IDs) 
%                    [default all mets with nonempty .metFormulas]
%    rxns:           The set of reactions for inferring formulae (cell array of strings or vector of IDs)
%                    [default all non-exchange reactions]
%    metFill:        The chemical formulas for compounds for freely filling the
%                    imbalance, e.g. {'HCharge1', 'H2O'} [default 'HCharge1']
%    findCM:         Find conserved moieties from the left null space of S. Options:
%                      * 'efmtool': Use EFMtool (most comprehensive, recommanded, but computational 
%                                   cost may be high if there are many deadend mets)
%                      * 'null':    Use the rational basis computed by Matlab 
%                      * N:         Directly supply the matrix :math:`N` for conserved moieties 
%                                   (rational basis or the set of extreme rays)
%                      * false:     Not to find conserved moieties and return minimal formulae
%                      [default 'efmtool' if 'CalculateFluxModes.m' is in path, else switch to rational basis]
%    nameCM:         Name the identified conserved moieties or not [default 0]
%                      * 0:  The program assigns default names for conserved moieties (Conserve_a, Conserve_b, ...)
%                      * 1:  Name true conserved moieties interactively (exclude dead end mets). 
%                      * 2:  Name all interactively (including dead end)
%    params:         Parameters for `solveCobraLP`, in a struct or name-value arguments. See `solveCobraLP` for details
%
% OUTPUTS:
%    model:          COBRA model with updated formulas
%    metCompute:     #unknown mets x 2 cel array [mets | computed formulas]
%    ele:            Elements corresponding to the row of rxnBal, the coloumn of metEle
%    metEle:         Chemical formulas in matrix (#metKnown x #elements)
%    rxnBal:         Elemental balance of rxns (#elements x #rxns)
%    S_fill:         Adjustment of the S-matrix by 'metFill' (#metFill x #rxns in the input)
%    solInfo:        Info for the Minimum Inconsistency under Parsimony optimization:
%                      * metUnknown:    mets whose formulae are being solved for (#met_unknown x 1 cell)
%                      * ele:           the original elements present in the model's formulae. 
%                                       May have less elements than the output 'ele' above. (#elements x 1 cell)
%                      * eleConnect:    connected components partitioning solInf.ele (#elements x #components logical matrix).
%                                       Elements in the same component mean that they are connected
%                                       by some 'metFill' and are optimized in the same round.
%                      * metEleUnknown: the formulae found for unknown metabolites (#met_unknown x #elements)
%                      * sol:           solutions returned by solveCobraLP, #components x 1 struct array, 
%                                       each with the following three solutions:
%                                         * .minIncon: minimum inconsistency (Step 1), 
%                                         * .minFill: minimum adjustment by filling metabolites (Step 2),
%                                         * .minForm: minimal formulae (Step 3)
%                      * var:           indices of variables corresponding to the vector solInfo.sol.full
%                                       (including .m.ele, .xp.ele, .xn.ele, .Ap.metFill, .An.metFill)
%                      * infeasibility: infeasibility of each solve (#components x 1 struct array,
%                                       each with .minIncon, .minFill and .minForm)
%                                       The problem is not solved successfully if infeasibility > solInfo.feasTol
%                      * bound:         * .minFill, bounds on total inconsistency for each element.
%                                       * .minForm, tolerance f used for relaxing the bounds on inconsistency
%                                                   and adjustment (ub = value x (1 + f), lb = value x (1 - f)) (#components x 1)
%                      * feasTol:       tolerance used to determine solution feasibility
%                      * stat:          cell array of minIncon/minFill/minForm/infeasible stating which 
%                                       solution is feasible for the optimization for each componenet in .eleConnect. 
%                      * final:         minIncon/minFill/minForm/mixed/infeasible stating where 
%                                       the final solution metEleUnknwon is obtained from. 
%                                       Ideally minForm if no numerical issue on feasibility.
%    N:              the set of extreme rays or the rational null space matrix
%    LP:             LP problem structure for solveCobraLP (#components x 1)

% As an internal parameter deciding to include dead end metabolites or not when calculating conserved moieties
deadCM = true;

if ~isfield(model,'metFormulas')
    error('model does not have the field ''metFormulas.''')
end
if nargin < 6 || isempty(nameCM)
    nameCM = 0;
end
if nargin < 5 || isempty(findCM)
    findCM = 'efmtool';
end
if nargin < 4 || isempty(metFill)
    % defaulted proton for filling imbalance
    metFill = {'HCharge1'};
elseif ischar(metFill)
    metFill = {metFill};
end
if nargin < 3 || isempty(rxns)
    rxns = find(sum(model.S~=0,1) > 1 & (model.lb ~= 0 | model.ub ~= 0)');
end
if ischar(rxns)
    rxns = {rxns};
end
if iscell(rxns)
    rxnC = findRxnIDs(model,rxns);
else
    rxnC = rxns;
end
if any(rxnC == 0)
    if iscell(rxns)
        error('%s in rxns is not in the model.', rxns{find(rxnC==0,1)});
    else
        error('rxns index must be positive integer.')
    end
end
if nargin < 2 || isempty(metKnown)
    metKnown = model.mets(~cellfun(@isempty,model.metFormulas));
end
if ischar(metKnown)
    metKnown = {metKnown};
end
if iscell(metKnown)
    metK = findMetIDs(model,metKnown);
else
    metK = metKnown;
end
if any(metK == 0) 
    if iscell(metKnown)
        error('%s in metKnown is not in the model.', metKnown{find(metK==0,1)});
    else
        error('metKnown index must be positive integer.')
    end
end
metKform = cellfun(@isempty,model.metFormulas(metK));
if any(metKform)
    warning('Some mets in metKnown do not have formulas in the model. Ignore them.');
end
% All formulas must be in the form of e.g. Abc2Bcd1. Elements are represented by one capital letter 
% followed by lower case letter or underscore, followed by a number for the stoichiometry. 
% Brackets/parentheses and repeated elements are also supported, e.g. CuSO4(H2O)5.
[metK,metKform] = deal(metK(~metKform), model.metFormulas(metK(~metKform)));

% get feasibility tolerance
if ~isempty(varargin) && isstruct(varargin{1}) && isfield(varargin{1}, 'feasTol')
    feasTol = varargin{1}.feasTol;
else
    feasTolInInput = find(strcmp(varargin,'feasTol'),1);
    if ~isempty(feasTolInInput)
        if feasTolInInput == numel(varargin) || ~isnumeric(varargin{feasTolInInput+1})
            error('Invalid input for the parameter feasTol.');
        end
        feasTol = varargin{find(feasTolInInput)+1};
    else
        feasTol = getCobraSolverParams('LP',{'feasTol'});
    end
end

digitRounded = 12;
%% Preprocess
% formulas for known metabolites
[~,eleK,metEleK] = checkEleBalance(metKform);
% formulas for filling metabolites
[~,eleK,metEleF] = checkEleBalance(metFill, eleK);
if numel(eleK) > size(metEleK,2)
    metEleK = [metEleK, zeros(size(metEleK,1), numel(eleK) - size(metEleK,2))];
end
eleCh = strcmp(eleK,'Charge');  % index for charge coloumn
m = size(model.S,1);  % number of mets
nE = numel(eleK);  % number of elements
mK = numel(metK);  % number of known mets
mU = m - mK;  % number of unknown mets
mF = numel(metFill);  % number of filling mets
metU = setdiff((1:m)',metK);  % index for unknown mets
nR = numel(rxnC);  % number of reactions that should be mass balanced

% elements connected because of metFill. They need to be optimized in the same problem.
eleConnect = false(nE);
eleUnchecked = true(nE,1);
nEC = 0;
while any(eleUnchecked)
    nEC = nEC + 1;
    jE = find(eleUnchecked, 1);
    eleConnect(jE, nEC) = true;
    metFillCon = any(metEleF(:, eleConnect(:,nEC)), 2);
    while true
        eleConnect(any(metEleF(metFillCon,:), 1), nEC) = true; 
        metFillConNext = any(metEleF(:, eleConnect(:,nEC)), 2);
        if ~any(metFillConNext & ~metFillCon)
            break
        end
        metFillCon = metFillConNext;
    end
    eleUnchecked(eleConnect(:,nEC)) = false;
end
eleConnect = eleConnect(:, 1:nEC);

%% main loop
% constraint matrix for m_ie, x^pos_je, x^neg_je: [S_unknown I_nR -I_nR]
[row,col,entry] = find([model.S(metU, rxnC)', speye(nR), -speye(nR)]);
nCol = mU + nR*2;
% chemical formulae
[metEleU.minIncon, metEleU.minFill, metEleU.minForm] = deal(NaN(mU, nE));
% infeasibility of each solve
[infeasibility,sol] = deal(repmat(struct('minIncon',[],'minFill',[],'minForm',[]), nEC, 1));
[S_fill.minIncon, S_fill.minFill, S_fill.minForm] = deal(sparse(mF, nR));
% bound on the total inconsistency allowed
bound = repmat(struct('minIncon',[],'minFill',[],'minForm',[]), nEC, 1);
index = repmat(struct('m',[],'xp',[],'xn',[],'Ap',[],'An',[]),nEC,1);
LP = repmat(struct('A',[],'b',[],'lb',[],'ub',[],'c',[],'csense',[],'osense',[]), nEC, 1);
for jEC = 1:nEC
    %% minimum inconsistency
    kE = sum(eleConnect(:,jEC));  % number of connected elements in the current component
    metFillCon = any(metEleF(:, eleConnect(:,jEC)), 2);  % connected mets for filling 
    mFC = sum(metFillCon);  % number of connected mets for filling
    % Matrix containing m_ie for all conected elements:
    % [S_unknown I_nR -I_nR 0 ...                                    0 ;
    %  0 ...              0 S_unknown I_nR -I_nR  0 ...              0 ;
    %  0 ...                                   0  S_unknown I_nR -I_nR ]
    rowJ = repmat(row(:), kE, 1) + reshape(repmat(0:nR:nR*(kE-1), numel(row), 1), numel(row)*kE, 1);
    colJ = repmat(col(:), kE, 1) + reshape(repmat(0:nCol:nCol*(kE-1), numel(col), 1), numel(col)*kE, 1);
    entryJ = repmat(entry(:), kE, 1);
    LP(jEC).A = sparse(rowJ, colJ, entryJ, nR*kE, nCol*kE);
    % Matrix for mets for filling (m_i,e for met i, element e, I_nR identity matrix):
    % [m_1,1 * I_nR  | m_2,1 * I_nR  | ... | m_mFC,1 * I_nR ;
    %  m_1,2 * I_nR  | m_2,2 * I_nR  | ... | m_mFC,2 * I_nR ;
    %  ...
    %  m_1,kE * I_nR | m_2,kE * I_nR | ... | m_mFC,kE * I_nR] 
    rowJ = repmat((1:nR*kE)', mFC, 1); 
    colJ = repmat((1:nR)', kE*mFC, 1) + reshape(repmat(0:nR:nR*(mFC-1), nR*kE, 1), nR*kE*mFC, 1);
    entryJ = full(metEleF(metFillCon,eleConnect(:,jEC))');
    entryJ = reshape(repmat(entryJ(:)', nR, 1), nR*kE*mFC, 1);
    LP(jEC).A = [LP(jEC).A, sparse(rowJ, colJ, entryJ, nR*kE, nR*mFC), -sparse(rowJ, colJ, entryJ, nR*kE, nR*mFC)];
    LP(jEC).lb = zeros(size(LP(jEC).A,2),1);
    [~, idCharge] = ismember(find(eleCh), find(eleConnect(:,jEC)));
    if idCharge > 0
        % charges can be negative
        LP(jEC).lb((nCol * (idCharge - 1) + 1) : (nCol * (idCharge - 1) + mU)) = -inf;
    end
    % store the index
    eleJ = eleK(eleConnect(:,jEC));
    for jkE = 1:kE
        index0 = (jkE-1)*(mU + nR*2);
        index(jEC).m.(eleJ{jkE}) = (index0 + 1) : (index0 + mU);
        index(jEC).xp.(eleJ{jkE}) = (index0 + mU + 1) : (index0 + mU + nR);
        index(jEC).xn.(eleJ{jkE}) = (index0 + mU + nR + 1) : (index0 + mU + nR*2);
    end
    if mFC > 0
        metFillConName = metFill(metFillCon);
        for jFC = 1:mFC
            index0 = kE*(mU + nR*2) + (jFC - 1) * nR;
            index(jEC).Ap.(metFillConName{jFC}) = (index0 + 1) : (index0 + nR);
            index(jEC).An.(metFillConName{jFC}) = (index0 + nR + 1) : (index0 + nR*2);
        end
    end
    
    LP(jEC).ub = inf(size(LP(jEC).A,2),1);
    % Objective: sum(x^pos_ie + x^neg_ie)
    LP(jEC).c = zeros(size(LP(jEC).A, 2), 1);
    for jkE = 1:kE
        LP(jEC).c((nCol * (jkE - 1) + mU + 1) : (nCol * jkE)) = 1;
    end
    % RHS: -S_known' * n_known
    LP(jEC).b = - model.S(metK,rxnC)' * metEleK(:,eleConnect(:,jEC));
    LP(jEC).b = LP(jEC).b(:);
    LP(jEC).csense = char('E' * ones(1, nR * kE));
    LP(jEC).osense = 1;  % minimize
    % solve for minimum inconsistency
    if nargin < 6
        sol(jEC).minIncon = solveCobraLP(LP(jEC));
    else
        sol(jEC).minIncon = solveCobraLP(LP(jEC), varargin{:});
    end
    if isfield(sol(jEC).minIncon,'full') && numel(sol(jEC).minIncon.full) == size(LP(jEC).A,2)
        % store the chemical formulae
        jkE = 0;
        for jE = 1:nE
            if eleConnect(jE, jEC)
                jkE = jkE + 1;
                metEleU.minIncon(:,jE) = sol(jEC).minIncon.full((nCol*(jkE - 1) + 1):(nCol*(jkE - 1) + mU));
            end
        end
        S_fill.minIncon(metFillCon,:) = reshape(...
            sol(jEC).minIncon.full((nCol * kE + 1) : (nCol * kE + nR * mFC)) ...
            - sol(jEC).minIncon.full((nCol * kE + nR * mFC + 1) : (nCol * kE + nR * mFC *2)), nR, mFC)';
    else
        metEleU.minIncon(:,eleConnect(:,jEC)) = NaN;
    end
    % manually check feasibility
    infeas = checkSolFeas(LP(jEC), sol(jEC).minIncon);
    infeasibility(jEC).minIncon = infeas;
    if infeas <= feasTol  % should always be feasible
        %% minimize the stoichiometric coefficients of mets for filling
        for jkE = 1:kE
            LP(jEC).A(end + 1,:) = 0;
            LP(jEC).A(end, (nCol*(jkE - 1) + mU + 1):(nCol*jkE)) = 1;
            LP(jEC).b(end + 1) = sum(sol(jEC).minIncon.full((nCol*(jkE - 1) + mU + 1):(nCol*jkE)));
        end
        LP(jEC).csense((end + 1):(end + kE)) = 'L';
        % rounding to avoid numerical issues on feasibility
        LP(jEC).b = round(LP(jEC).b, digitRounded);
        % reuse basis
        if isfield(sol(jEC).minIncon, 'basis')
            LP(jEC).basis = sol(jEC).minIncon.basis;
            if isstruct(LP(jEC).basis) && isfield(LP(jEC).basis, 'cbasis')
                LP(jEC).basis.cbasis((end + 1) : (end + kE)) = 0;
            end
        end
        % inconsistency for each element
        bound(jEC).minIncon = LP(jEC).b((end - kE + 1) : end);
        % change objective to min adjustment
        LP(jEC).c(:) = 0;
        LP(jEC).c((nCol * kE + 1) : (nCol * kE + nR * mFC * 2)) = 1;
        % solve, adjust tolerance if infeasible
        f = 1e-6;
        while true
            if nargin < 6
                sol(jEC).minFill = solveCobraLP(LP(jEC));
            else
                sol(jEC).minFill = solveCobraLP(LP(jEC), varargin{:});
            end
            infeas = checkSolFeas(LP(jEC), sol(jEC).minFill);
            if infeas <= feasTol || f > 1e-4 + 1e-8
                break
            end
            f = f * 10;
            LP(jEC).b((end - kE + 1) : end) = bound(jEC).minIncon * (1 + f);
            % rounding to avoid numerical issues on feasibility
            LP(jEC).b = round(LP(jEC).b, digitRounded);
        end
        if isfield(sol(jEC).minFill,'full') && numel(sol(jEC).minFill.full) == size(LP(jEC).A,2)
            % store the chemical formulae
            jkE = 0;
            for jE = 1:nE
                if eleConnect(jE, jEC)
                    jkE = jkE + 1;
                    metEleU.minFill(:,jE) = sol(jEC).minFill.full((nCol*(jkE - 1) + 1):(nCol*(jkE - 1) + mU));
                end
            end
            S_fill.minFill(metFillCon,:) = reshape(...
                sol(jEC).minFill.full((nCol * kE + 1) : (nCol * kE + nR * mFC)) ...
                - sol(jEC).minFill.full((nCol * kE + nR * mFC + 1) : (nCol * kE + nR * mFC *2)), nR, mFC)';
        else
            metEleU.minFill(:,eleConnect(:,jEC)) = NaN;
        end
        infeasibility(jEC).minFill = infeas;
        bound(jEC).minFill = LP(jEC).b((end - kE + 1) : end);
        %% minimal formulas
        if infeas <= feasTol
            % feasible solution found. Use sol.minFill to constrain
            solChoice = 'minFill';
        else
            % infeasible when minimizing stoichiometric coefficients of
            % filling mets. Use sol.minIncon to constrain
            solChoice = 'minIncon'; 
        end
        % remove constraint on total inconsistency
        LP(jEC).A((end - kE + 1) : end, :) = [];
        LP(jEC).b((end - kE + 1) : end) = [];
        LP(jEC).csense((end - kE + 1) : end) = '';
        if isfield(LP(jEC), 'basis') && isfield(LP(jEC).basis, 'cbasis')
            LP(jEC).basis.cbasis((end - kE + 1) : end) = [];
        end
        LP(jEC).c(:) = 0;  % reset objective
        % if charge is involved, split it into m^pos, m^neg
        if idCharge > 0
            LP(jEC).A = [LP(jEC).A sparse(size(LP(jEC).A,1), mU*2); sparse(1:mU, (nCol * (idCharge - 1) + 1) : (nCol * (idCharge - 1) + mU), ...
                ones(mU, 1), mU, size(LP(jEC).A,2)), -speye(mU), speye(mU)];
            LP(jEC).b = [LP(jEC).b; zeros(mU, 1)];
            LP(jEC).csense = [LP(jEC).csense char('E' * ones(1,mU))];
            LP(jEC).lb = [LP(jEC).lb; zeros(mU*2, 1)];
            LP(jEC).ub = [LP(jEC).ub; inf(mU*2, 1)];
            LP(jEC).c = [LP(jEC).c; ones(mU*2, 1)];
            if isfield(LP(jEC), 'basis') 
                if isstruct(LP(jEC).basis)
                    % for gurobi
                    if isfield(LP(jEC).basis, 'vbasis')
                        LP(jEC).basis.vbasis((end + 1) : (end + mU * 2)) = 0;
                    end
                    if isfield(LP(jEC).basis, 'cbasis')
                        LP(jEC).basis.cbasis((end + 1) : (end + mU)) = 0;
                    end
                else
                    % for other solvers
                    if numel(LP(jEC).basis) == size(LP(jEC).A, 2) - mU * 2
                        LP(jEC).basis((end + 1) : (end + mU * 2)) = 0;
                    end
                end
            end
        end
        for jkE = 1:kE
            % fix inconsistency variables
            ind = (nCol * (jkE - 1) + mU + 1) : (nCol * jkE);
            LP(jEC).ub(ind) = sol(jEC).(solChoice).full(ind) * (1 + 1e-10);
            LP(jEC).lb(ind) = sol(jEC).(solChoice).full(ind) * (1 - 1e-10);
            % minimize chemical formulae
            if jkE ~= idCharge
                LP(jEC).c((nCol * (jkE - 1) + 1) : (nCol * (jkE - 1) + mU)) = 1;
            end
        end
        % fix stoichiometric coefficients for filling mets
        LP(jEC).ub((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) ...
            = sol(jEC).(solChoice).full((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) * (1 + 1e-10);
        LP(jEC).lb((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) ...
            = sol(jEC).(solChoice).full((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) * (1 - 1e-10);
        % rounding to avoid numerical issues on feasibility
        LP(jEC).ub = round(LP(jEC).ub, digitRounded);
        LP(jEC).lb = round(LP(jEC).lb, digitRounded);
        % solve, adjust tolerance if infeasible
        f = 1e-10;
        while true
            if nargin < 6
                sol(jEC).minForm = solveCobraLP(LP(jEC));
            else
                sol(jEC).minForm = solveCobraLP(LP(jEC), varargin{:});
            end
            infeas = checkSolFeas(LP(jEC), sol(jEC).minForm);
            if infeas <= feasTol || f > 1e-5
                break
            end
            f = f * 10;
            for jkE = 1:kE
                % relax tolerance
                ind = (nCol * (jkE - 1) + mU + 1) : (nCol * jkE);
                LP(jEC).ub(ind) = sol(jEC).(solChoice).full(ind) * (1 + f);
                LP(jEC).lb(ind) = sol(jEC).(solChoice).full(ind) * (1 - f);
            end
            LP(jEC).ub((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) ...
                = sol(jEC).(solChoice).full((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) * (1 + f);
            LP(jEC).lb((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) ...
                = sol(jEC).(solChoice).full((nCol * kE + 1) : (nCol * kE + nR*2*mFC)) * (1 - f);
            % rounding to avoid numerical issues on feasibility
            LP(jEC).ub = round(LP(jEC).ub, digitRounded);
            LP(jEC).lb = round(LP(jEC).lb, digitRounded);
        end
        if isfield(sol(jEC).minForm,'full') && numel(sol(jEC).minForm.full) == size(LP(jEC).A,2)
            % store the chemical formulae
            jkE = 0;
            for jE = 1:nE
                if eleConnect(jE, jEC)
                    jkE = jkE + 1;
                    metEleU.minForm(:,jE) = sol(jEC).minForm.full((nCol*(jkE - 1) + 1):(nCol*(jkE - 1) + mU));
                end
            end
            S_fill.minForm(metFillCon,:) = reshape(...
                sol(jEC).minForm.full((nCol * kE + 1) : (nCol * kE + nR * mFC)) ...
                - sol(jEC).minForm.full((nCol * kE + nR * mFC + 1) : (nCol * kE + nR * mFC *2)), nR, mFC)';
        else
            metEleU.minForm(:,eleConnect(:,jEC)) = NaN;
        end
        infeasibility(jEC).minForm = infeas;
        bound(jEC).minForm = f;
    else
        [infeasibility(jEC).minFill, infeasibility(jEC).minForm] = deal(inf);
    end
end
%% store the solution and relevant info
solInfo.metUnknown = model.mets(metU);
solInfo.ele = eleK;
solInfo.eleConnect = eleConnect;
solInfo.rxns = model.rxns(rxnC);
solInfo.metEleUnknwon = metEleU;
solInfo.S_fill = S_fill;
solInfo.sol = sol;
solInfo.var = index;
solInfo.infeasibility = infeasibility;
solInfo.bound = bound;
solInfo.feasTol = feasTol;
solInfo.stat = repmat({'infeasible'}, nEC, 1);
solInfo.stat([infeasibility.minIncon] <= feasTol) = {'minIncon'};
solInfo.stat([infeasibility.minFill] <= feasTol) = {'minFill'};
solInfo.stat([infeasibility.minForm] <= feasTol) = {'minForm'};
if any(strcmp(solInfo.stat, 'infeasible'))
    fprintf('Critical failure: no feasible solution is found.\n')
    metCompute = {};
    solInfo.final = 'infeasible';
    return
elseif all(strcmp(solInfo.stat, 'minForm'))
    solInfo.final = 'minForm';
elseif all(strcmp(solInfo.stat, 'minFill'))
    solInfo.final = 'minFill';
elseif all(strcmp(solInfo.stat, 'minIncon'))
    solInfo.final = 'minIncon';
else
    solInfo.final = 'mixed';
end
% Get the best metEle and S_fill as the solution for incorporating results from conserved moiety calculations. 
% For each set of elements in eleConnect, choose the latest solution (minForm > minFill > minIncon), recorded in solInfo.stat.
metEle = zeros(m, nE);
metEle(metK,:) = metEleK;
S_fill = sparse(mF, numel(model.rxns));
for jEC = 1:nEC
    metEle(metU,eleConnect(:,jEC)) = metEleU.(solInfo.stat{jEC})(:, eleConnect(:,jEC));
    metFillCon = any(metEleF(:, eleConnect(:,jEC)), 2);
    if any(metFillCon)
        S_fill(metFillCon, rxnC) = solInfo.S_fill.(solInfo.stat{jEC})(metFillCon, :);
    end
end
%% find conserved moieties
if nargin < 4 || isempty(findCM) || (numel(findCM) == 1 && findCM)
    findCM = 'efmtool';
end
CMfound = false;
N = [];
if size(findCM,1) == numel(model.mets)
    % input is the null space matrix / set of extreme rays
    N = findCM;
    CMfound = true;
elseif ~ischar(findCM) && numel(findCM) > 1
    warning('Input extreme ray matrix has #rows (%d) different from #mets (%d). Ignore.', size(findCM,1), numel(model.mets));
    findCM = 'efmtool';
end
if ~CMfound && ischar(findCM) && strcmpi(findCM, 'efmtool')
    % use EFMtool
    pathEFM = which('CalculateFluxModes.m');
    if isempty(pathEFM)
        warning('EFMtool not in Matlab path. Use rational basis.');
        findCM = 'null';
    else
        dirEFM = strsplit(pathEFM,filesep);
        dirEFM = strjoin(dirEFM(1:end-1),filesep);
        dirCur = pwd;
        cd(dirEFM);
        if deadCM
            % may fail due to lack of memory if there are a lot of dead end 
            % metabolites, set deadCM = false to exclude them
            N = CalculateFluxModes(full(model.S'),zeros(numel(model.mets),1));
            N = N.efms;
        else
            [~,removedMets] = removeDeadEnds(model);
            metActive = true(numel(model.mets), 1);
            metActive(findMetIDs(model,removedMets)) = false;
            N_active = CalculateFluxModes(full(model.S(metActive,:)'),zeros(sum(metActive),1));
            N = zeros(numel(model.mets), size(N_active.efms,2));
            N(metActive,:) = N_active.efms;
        end
        cd(dirCur);
        CMfound = true;
    end
end
if ~CMfound && ischar(findCM) && strcmpi(findCM, 'null')
    % matlab rational basis
    if deadCM
        N = null(full(model.S'),'r');
    else
        [~,removedMets] = removeDeadEnds(model);
        metActive = true(numel(model.mets), 1);
        metActive(findMetIDs(model,removedMets)) = false;
        N_active = null(full(model.S(metActive,:)'),'r');
        N = zeros(numel(model.mets), size(N_active, 2));
        N(metActive,:) = N_active;
    end
    CMfound = true;
end
if CMfound
    fprintf('Conserved moieties found.\n');    
    % clear close-to-zero values
    N(abs(N) < 1e-8) = 0;
    N = sparse(N);
    % true generic conserved moieties, positive and not involving known mets
    Ncm = N(:,~any(N < 0, 1) & ~any(N(metK,:),1));
    % add them into formulas
    metEle = [metEle, Ncm];
    ele = [eleK(:); cell(size(Ncm,2),1)];
    j2 = 1;
    for j = 1:size(Ncm,2)
        while any(strcmp(ele(1:nE),['Conserve_' num2alpha(j2)]))
            j2 = j2 + 1;
        end
        ele{nE+j} = ['Conserve_' num2alpha(j2)];
        j2 = j2 + 1;
    end
else
    ele = eleK(:);
end

% get formulae in string
model.metFormulas = convertMatrixFormulas(ele,metEle,10);
if nameCM > 0 && CMfound
    % manually name conserved moieties
    ele0 = ele;
    nDefault = 0;
    nCM = size(Ncm,2);
    eleDel = false(nE + nCM, 1);
    if nameCM == 1
        % get dead end metatbolites
        [~,removedMets] = removeDeadEnds(model);
        metDead = findMetIDs(model,removedMets);
    end
    for j = 1:nCM
        fprintf('\n');
        writeCell2Text([model.mets(Ncm(:,j)~=0),model.metFormulas(Ncm(:,j)~=0),...
            model.metNames(Ncm(:,j)~=0)]);
        fprintf('\n');
        if nameCM == 1 && any(Ncm(metDead,j),1)
            % use the defaulted for dead end mets
            nDefault = nDefault + 1;
            ele{nE+j} = ele0{nE + nDefault};
        else
            cont = false;
            while true
                s = input(['Enter the formula for the conserved moiety (e.g. OHRab_cd):\n',...
                    '(hit return to use default name ''Conserve_xxx'')\n'],'s');
                if isempty(s)
                    % use the defaulted
                    nDefault = nDefault + 1;
                    ele{nE+j} = ele0{nE + nDefault};
                    break
                end
                re = regexp(s,'[A-Z][a-z_]*(\-?\d+\.?\d*)?','match');
                if strcmp(strjoin(re,''),s)
                    % manual input formula, continue to checking
                    cont = true;
                    break
                end
            end
            if cont
                % get the matrix for the input formula
                nEnew = numel(ele) - nE - nCM;
                [~, eleJ, metEleJ] = checkEleBalance(s,ele([1:nE, (nE+nCM+1):end]));
                metEle(:,[1:nE, (nE+nCM+1):end]) ...
                    = metEle(:,[1:nE, (nE+nCM+1):end])...
                        + metEle(:,nE+j) * metEleJ(1,1:(nE+nEnew));
                if numel(eleJ) > nE + nEnew
                    % there are new elements
                    ele = [ele(:); eleJ((numel(ele)-nCM+1):end)];
                    metEle = [metEle, ...
                        metEle(:,nE+j) * metEleJ(1,(nE+nEnew+1):end)];
                end
                eleDel(nE + j) = true;
            end
        end
    end
    % del defaulted but replaced columns
    if any(eleDel)
        eleDel = find(eleDel);
        ele(eleDel) = [];
        metEle(:,eleDel) = [];
    end
    % 1:nE                    :    real elements
    % nE + 1 : nE + nDefault  :    default generic elements (Conserve_xxx)
    % nE + nDeafult + 1 : end :    generic element by user's input
    % Change if names of default generic elements are mixed up with user input
    j0 = 0;
    for j = 1:nDefault
        j0 = j0 + 1;
        nameJ = ['Conserve_' num2alpha(j0)];
        while any(strcmp(ele([1:nE, nE+nDefault+1:end]),nameJ))
            j0 = j0 + 1;
            nameJ = ['Conserve_' num2alpha(j0)];
        end
        ele{nE+j} = nameJ;
    end
end
% reaction balance
rxnBal = metEle' * model.S;
model.metFormulas = convertMatrixFormulas(ele,metEle,10);
metCompute = [model.mets(metU) model.metFormulas(metU)];
end

function s = num2alpha(index,charSet)
% s = num2alpha(j, charSet)
% Given a nonzero integer j and a character set charSet, convert j into
% a string formed from the characters in charSet having order j.
% 'charSet' defaulted to be '_abcdefghijklmnopqrstuvwxyz' in which '_' acts
% like 0 and 'z' acts like the largest digit 9 in decimal expression
% e.g. num2slpha(0) is '_' , num2slpha(1) is 'a', num2slpha(27^2) is 'a__'

if nargin < 2
    charSet = ['_' char(97:122)];
end
if numel(index) > 1
    s = cell(numel(index),1);
    for j = 1:numel(index)
        s{j} = num2alpha(index(j),charSet);
    end
    return
end
N = length(charSet);
s = '';
k = floor(index/N);
while k > 0
    s = [charSet(index - k*N + 1) s];
    index = k;
    k = floor(index/N);
end
s = [charSet(index + 1) s];
end