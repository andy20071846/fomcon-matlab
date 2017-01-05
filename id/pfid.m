function [idp, G] = pfid(iddata, expr, params, mparams, op)
%PFID Parametrized freq. or time domain identification of FOTF SISO systems
%   
%Usage: [IDPARAMS,G] = PFID(FIDATA|FFIDATA,EXPR|FSIM,PARAMS,MPARAMS,OP)
%
% Where IDPARAMS is a structure with identified parameters,
%       G  is a FOTF object holding the identified model,
%
%       FIDATA is a FIDATA object with time domain data,
%    or FFIDATA is a FFIDATA object with frequency domain data,
%       EXPR is a symbolic expression with the FOTF model structure, e.g.
%
%         EXPR = 'p_1/(1+T*s^{q_1}) exp(-q_2*s)'; % Defines a FFOPDT model
%                                                 % with T (time constant)
%                                                 % known in advance
%       OR FSIM is a simulation object of type FSPARAM with a valid
%               .fotf_expr parameter which must be formatted exactly as
%               EXPR in the above example.
%
%       PARAMS (optional) is a structure holding the model parameter
%       min/initial/max values, i.e.
%       params.p_1 = p_1_ini or
%       params.p_1 = [p_1_min, p_1_max] or
%       params.p_1 = [p_1_min, p_1_ini, p_1_max]. This is an optional
%       argument. Set parameters in the following format: "pk", "p_k",
%       "qk", "q_k", where k is some integer number. The difference between
%       "p" and "q" parameters is that if min/max values are not provided
%       for "q", the default search range will be [0, Inf], while in case
%       of "p" it will be [-Inf, +Inf], for supported algorithms.
%       Therefore, it is suggested to use "q" parameters for fractional
%       powers and lags. Supply "[]" as an argument to use default values
%       (min/ini/max generated automatically). Default values will also be
%       used in case some of the parameter min/ini/max values are missing
%       from the structure supplied.
%       OP holds additional optimization options for lsqnonlin (use
%       optimset). Note, that you can set the preferred optimization
%       algorithm here. This is done as follows:
%            OP.IdentificationAlgorithm = 'trr':
%            Trust-Region-Reflective algorithm is used;
%            OP.IdentificationAlgorithm = 'lm':
%            Levenberg-Marquardt algorithm is used, for the latter
%            OP.Lambda determines the lambda parameter, 0.01 by default.
%            This algorithm does not support bound constraints, so only q
%            parameters will be bound from below using a coordinate
%            transformation method. NB! the algorithm choice has priority
%            over setting the bounds unlike a direct call to, e.g.,
%            LSQNONLIN. So if you supply min/max values for the parameters,
%            the LM algorithm will still be used while the min/max values
%            will be ignored. A warning will be generated.
%            OP.IdentificationAlgorithm = 'nm':
%            Nelder-Mead simplex method is used.
%            NB! You cannot write optimset("IdentificationAlgorithm", ...)
%            as this is a separate parameter not directly supported by the
%            Optimization toolbox. First create the optimset structure and
%            then add this parameter via dot notation (as shown above).

% Load the FOMCON configuration file and read significant digits number
config    = fomcon('config');
numDigits = config.Core.General.Model_significant_digits;

% Default ranges / initial values
P_DEFAULT = [-Inf, 1, Inf];
Q_DEFAULT = [0, 1, Inf];

% Check input arguments
if nargin < 2
    error('PFID:NotEnoughInputArguments', 'Not enough input arguments.');
end

if ~isa(iddata,'fidata') && ~isa(iddata, 'ffidata')
    error('PFID:InvalidIdentificationData', ...
          ['First argument must be a valid identification ' ...
           'dataset of class FIDATA or FFIDATA']);
end

% Get the expression
if isa(expr, 'fsparam')
    simParam = expr;
    expr = simParam.fotf_expr;
elseif isa(expr, 'char')
    simParam = [];
end
    
% If model parameters are supplied, replace them
% This is done before parsing for actual parameters, because
% some of the parameters may be found during the whole procedure
% but the user need not change the parametrized transfer function
if nargin >= 4 && ~isempty(mparams)
    % Get all parameters
    allModelParams = fieldnames(mparams);
    for k=1:length(allModelParams)
       expr = strrep(expr, allModelParams{k}, ...
             num2str(mparams.(allModelParams{k}),numDigits));
    end
end

% Parse string using regular expressions and determine all unique entries
paramsP   = unique(regexp(expr, 'p_?[0-9]+', 'match'));
paramsQ   = unique(regexp(expr, 'q_?[0-9]+', 'match'));

% Get parameter indices
indP = []; indQ = [];
if ~isempty(paramsP)
    indP = str2double(regexp([paramsP{:}], '[0-9]+', 'match'));
end
if ~isempty (paramsQ)
    indQ   = str2double(regexp([paramsQ{:}], '[0-9]+', 'match'));
end

% Determine all unique entries
paramsAll  = [paramsP paramsQ];
numParamsP = length(paramsP); numParamsQ = length(paramsQ);
sizes      = [numParamsP numParamsQ];
numParams  = length(paramsAll);

% Check resulting array
if isempty(paramsAll)
   error('PFID:NoParametersToIdentify', ...
         'There are no parameters to identify.'); 
end

% Replace id parameters with vectors
expr      = regexprep(expr, '([p|q])_?([0-9]+)', '$1($2)');

% Check the OP argument

% Optimization options and algorithm choice
% 1: Trust-Region-Reflective
% 2: Levenberg-Marquardt
% 3: Nelder-Mead Simplex Method
alg = 1;
if nargin < 5
    op = optimset('Display','iter');
else
    % Determine the algorithm and set parameters accordingly
    if cfieldexists(op, 'IdentificationAlgorithm')
        switch lower(op.IdentificationAlgorithm)
            case 'lm'
                alg = 2;
                op.Algorithm = 'levenberg-marquardt';
                if cfieldexists(op, 'Lambda') && isnumeric(op.Lambda)
                    op.Algorithm = {'levenberg-marquardt', op.Lambda};
                end
            case 'nm'
                alg = 3;
        end
    end
end

% Set default values
p_min = P_DEFAULT(1)*ones(numParamsP,1);
p_ini = P_DEFAULT(2)*ones(numParamsP,1);
p_max = P_DEFAULT(3)*ones(numParamsP,1);

q_min = Q_DEFAULT(1)*ones(numParamsQ,1);
q_ini = Q_DEFAULT(2)*ones(numParamsQ,1);
q_max = Q_DEFAULT(3)*ones(numParamsQ,1);

% Construct full min/ini/max vectors
x_min = [p_min; q_min];
x_max = [p_max; q_max];
x_ini = [p_ini; q_ini];

if (nargin > 2 && ~isempty(params))
    % Correct minimum, maximum, and initial value vectors
    % for entries for which such information is provided
    customParams = fieldnames(params);
    for k=1:numParams
       if ~isempty(find(ismember(customParams, paramsAll{k}), 1))
           vals = params.(paramsAll{k});
           % Ini supplied
           if length(vals) == 1
              x_ini(k) = vals; 
           % Min/max supplied
           elseif length(vals) == 2
              if (alg==2)
                  warning(['Levenberg-Marquard algorithm does not support'
                      ' bound constraints. Ignoring min/max for parameter'
                      ' ' paramsAll{k}]);
              end
              x_min(k) = vals(1);
              x_max(k) = vals(2);
           % Min/ini/max supplied
           elseif length(vals) == 3
              if (alg==2)
                  warning(['Levenberg-Marquard algorithm does not support'
                      ' bound constraints. Ignoring min/max for parameter'
                      ' ' paramsAll{k}]);
              end 
              x_min(k) = vals(1);
              x_ini(k) = vals(2);
              x_max(k) = vals(3);
           end
       end
    end
end

% Transformation of coordinates for the LM algorithm
x_ini = convertToLM(x_ini, alg, sizes);

% Set the algorithm options
opt = struct;
opt.x_min = x_min;
opt.x_max = x_max;
opt.alg = alg;

% Depending on the data type, define select the correct cost computation
if isa(iddata, 'fidata')
    idcost = @fracparidfun;
elseif isa(iddata, 'ffidata')
    idcost = @fracparfidfun;
end

% Perform the identification

% Disable pbar if enabled
sp = show_pbar(); if sp, show_pbar('off'); end

% Measure time
elTime = tic;

switch alg
    
    case 1
        [x, resNorm] = ...
            lsqnonlin(@(x) idcost(x, expr, simParam, sizes, indP, indQ, iddata, opt), ...
            x_ini, ...
            x_min, ...
            x_max, ...
            op);
        
    case 2
        
        [x, resNorm] = ...
            lsqnonlin(@(x) idcost(x, expr, simParam, sizes, indP, indQ, iddata, opt), ...
            x_ini, ...
            [], ...
            [], ...
            op);
        
    case 3
        
        [x, resNorm] = ...
            optimize(@(x) sum(idcost(x, expr, simParam, sizes, indP, indQ, iddata, opt).^2), ...
            x_ini, ...
            x_min, ...
            x_max, ...
            [], [], [], [], [], [], op);
        
end

% Measure elapsed time
elTime = stohms(toc(elTime));

% Display elapsed time, if have 'Display' set to 'iter' in OP
if cfieldexists(op, 'Display') && strcmpi(op.Display, 'iter')
    elTime = ['Elapsed time: ' elTime];
    disp(elTime);
    disp(char('-'*ones(1,length(elTime))));
    disp(['Residual norm: ' num2str(resNorm,numDigits)]);
    disp('Identification completed.');
end

% Re-enable pbar
if sp, show_pbar('on'); end

% Coordinate transformation
x = convertFromLM(x, alg, sizes);

% Construct the output structure
idp = struct;
for k=1:numParams
    idp.(paramsAll{k}) = x(k);
end

% Return the fotf object as well
p(indP) = x(1:numParamsP);
q(indQ) = x(numParamsP+1:numParamsP+numParamsQ);
s = fotf('s');
G = eval(expr);

end

function z = fracparidfun(x, expr, spm, sizes, indP, indQ, id, opt)

% Do the transformation, if necessary
x = convertFromLM(x, opt.alg, sizes);

% Recover the parameters
if sizes(1) ~= 0
   p(indP) = x(1:sizes(1)); 
end

if sizes(2) ~= 0
   q(indQ) = x(sizes(1)+1:sizes(1)+sizes(2));
end

% Construct the FOTF
s = fotf('s');
G = eval(expr);

% Get identification data
y = id.y;
u = id.u;
t = id.t;

% Determine the type of simulation to perform
if isempty(spm)
    % Simulate system using GL based solver
    y_id = lsim(G,u,t);
else
    % Use the approximation
    Z = oustapp(G, spm.w(1), spm.w(2), spm.N, spm.approx);
    y_id = lsim(Z, u, t);
end
 
% Return error
z = y - y_id;

end

function z = fracparfidfun(x, expr, spm, sizes, indP, indQ, id, opt)

% Do the transformation, if necessary
x = convertFromLM(x, opt.alg, sizes);

% Recover the parameters
if sizes(1) ~= 0
   p(indP) = x(1:sizes(1)); 
end

if sizes(2) ~= 0
   q(indQ) = x(sizes(1)+1:sizes(1)+sizes(2));
end

% Construct the FOTF
s = fotf('s');
G = eval(expr);

% Get and transform the identification data
magn = id.mag;
phas = id.phase;

% Complex response and frequencies
r = 10.^(magn./20).*exp(deg2rad(phas).*1i);
w = id.w;

% Compute the response using whatever method
if isempty(spm)
    % Compute frequency response for fotf object
    r1 = squeeze(freqresp(G, w));
else
    % Use the approximation
    Z = oustapp(G, spm.w(1), spm.w(2), spm.N, spm.approx);
    r1 = squeeze(freqresp(Z, w));
end

% Column vector difference operation
z = cminus(r1, r);

% Distance between points in complex plane comprise the residual vector
for n=1:numel(z)
    z(n) = norm(z(n));
end

end

% Conversion *to* LM coordinates for Q parameters (lower bounds)
function nq1 = convertToLM(nq, alg, sizes)
    nq1=nq;
    if (alg==2) && sizes(2) ~= 0
        nq1(sizes(1)+1:sizes(1)+sizes(2)) = ...
            sqrt(nq(sizes(1)+1:sizes(1)+sizes(2)));
    end 
end

% Conversion *from* LM coordinates for Q parameters (lower bounds)
function nq1 = convertFromLM(nq, alg, sizes)
    nq1=nq;
    if (alg==2) && sizes(2) ~= 0
        nq1(sizes(1)+1:sizes(1)+sizes(2)) = ...
            (nq(sizes(1)+1:sizes(1)+sizes(2))).^2;
    end
end

