classdef UKalmanFilterX < KalmanFilterX
    % UKalmanFilterX class
    %
    % Summary of UKalmanFilterX:
    % This is a class implementation of a scaled Unscented Kalman Filter.
    %
    % UKalmanFilterX Properties:
    %    - config       = structure, with fields:
    %       .k          = time index. Can also act as a time interval (Dt), depending on the underlying models. 
    %       .x (*)      = Estimated state mean (x_{k|k}) - (nx x 1) column vector, where nx is the dimensionality of the state
    %       .P (*)      = Estimated state covariance (P_{k|k}) - (nx x nx) matrix 
    %       .x_pred     = Predicted state mean (x_{k|k-1}) - (nx x 1) column vector
    %       .P_pred     = Predicted state mean (P_{k|k-1}) - (nx x nx) matrix
    %       .y          = Measurement (y_k) - (ny x 1) column vector, where ny is the dimensionality of the measurement
    %       .y_pred     = Predicted measurement mean (H*x_{k|k-1}) - (ny x 1) column vector
    %       .S          = Innovation covariance (S_k) - (ny x ny) column vector
    %       .K          = Kalman Gain (K_k) - (ny x ny) column vector
    %       .alpha      = Default 0.5 |
    %       .kappa      = Default 0   |=> UKF scaling parameters
    %       .beta       = Default 2   |
    %   
    %   - dyn_model (*)   = Object handle to Dynamic Model Class
    %   - obs_model (*)   = Object handle to Observation Model Class
    %
    %   (*) Signifies properties necessary to instantiate a class object
    %
    % UKalmanFilterX Methods:
    %    UKalmanFilterX  - Constructor method
    %    Predict         - Performs UKF prediction step
    %    Update          - Performs UKF update step
    %    Iterate         - Performs a complete EKF iteration (Predict & Update)
    %    Smooth          - Performs UKF smoothing on a provided set of estimates
    % 
    % UKalmanFilterX Example:
  
    properties
    end
    
    methods
        function obj = UKalmanFilterX(config, dyn_model, obs_model)
        % UKalmanFilterX - Constructor method
        %   
        %   Inputs:
        %       config    |
        %       dyn_model | => Check class help for more details
        %       obs_model |
        %   
        %   Usage:
        %       ukf = UKalmanFilterX(config, dyn_model, obs_model); 
        %
        %   See also Predict, Update, Iterate, Smooth.
        
            % Validate alpha, kappa, betta
            if ~isfield(config,'alpha'); disp('[UKF] No alpha provided.. Setting "alpha=0.5"...'); config.alpha = 0.5; end
            if ~isfield(config,'kappa'); disp('[UKF] No kappa provided.. Setting "kappa=0"...'); config.kappa = 0; end
            if ~isfield(config,'beta'); disp('[UKF] No beta provided.. Setting "beta=2"...'); config.beta = 2; end
            obj@KalmanFilterX(config, dyn_model, obs_model);
        end
        
        function Predict(obj)
        % Predict - Performs UKF prediction step
        %   
        %   Inputs:
        %       N/A 
        %   (NOTE: The time index/interval "obj.config.k" needs to be updated, when necessary, before calling this method) 
        %   
        %   Usage:
        %       (ukf.config.k = 1; % 1 sec)
        %       ukf.Predict();
        %
        %   See also UKalmanFilterX, Update, Iterate, Smooth.
        
            nx = numel(obj.config.x);       % State dims
            nw = nx;                        % State noise dims
            ny = obj.obs_model.config.dim;  % Observation dims
            nv = ny;                        % Observation noise dims

            % Parameters for the UKF
            na = nx + nw + nv;              % Augmented state dims
            obj.config.lambda = (obj.config.alpha^2)*(na + obj.config.kappa) - na;
                        
            % Augment state and covariance
            xa = [obj.config.x; zeros(nw,1); zeros(nv,1)]; % x^a_{k-1} = [x_k-1 E[w] E[v]]
            Pa = blkdiag(obj.config.P, obj.dyn_model.config.Q(obj.config.k), obj.obs_model.config.R(obj.config.k));
            
            % Scaling parameters and sigma-points
            [Si,flag] = chol((na + obj.config.lambda)*Pa, 'lower');
            if flag ~= 0
                SP = nearestSPD((na + obj.config.lambda)*Pa); % Ensure Pa_km1 is positive semi-definite matrix
                Si = chol(SP, 'lower');
            end
            
            % Form Augmented Sigma points
            Xa = zeros(na,2*na+1);
            Xa(:,1) = xa;
            Xa(:,2:na+1) = xa*ones(1,na) + Si(:,1:na);
            Xa(:,na+2:2*na+1) = xa*ones(1,na) - Si(:,1:na);
            obj.config.X = Xa(1:nx,:);
            
            % Compute Sigma Weights
            obj.config.Wm = [obj.config.lambda/(na + obj.config.lambda) repmat(1/(2*(na + obj.config.lambda)),1,2*na)];
            obj.config.Wc = obj.config.Wm;
            obj.config.Wc(1,1) = obj.config.Wm(1,1) + (1 -obj.config.alpha^2 + obj.config.beta);

            % Unscented Tranform
            [obj.config.x_pred, obj.config.X_pred, obj.config.P_pred, X1] = obj.UnscentedTransform( @(X)obj.dyn_model.sys(obj.config.k,X), Xa(1:nx,:), obj.config.Wm, obj.config.Wc, Xa(nx+1:nx+nw,:));
            [obj.config.y_pred, obj.config.Y_pred, obj.config.S, Y1] = obj.UnscentedTransform( @(X)obj.obs_model.obs(obj.config.k,X), obj.config.X_pred, obj.config.Wm, obj.config.Wc, Xa(nx+nw+1:na,:));
      
            % Predicted state and measurements cross-covariances
            obj.config.Pxy = X1*diag(obj.config.Wc)*Y1';
        end
        
        function Update(obj)
        % Update - Performs UKF update step
        %   
        %   Inputs:
        %       N/A 
        %   (NOTE: The measurement "obj.config.y" needs to be updated, when necessary, before calling this method) 
        %   
        %   Usage:
        %       (ukf.config.y = y_new; % y_new is the new measurement)
        %       ukf.Update(); 
        %
        %   See also UKalmanFilterX, Predict, Iterate, Smooth.
        
            % Compute Kalman gain
            obj.config.K = obj.config.Pxy/obj.config.S;
            
            % Compute filtered estimates
            obj.config.x = obj.config.x_pred + obj.config.K * (obj.config.y-obj.config.y_pred);     %state update
            obj.config.P = obj.config.P_pred - obj.config.K*obj.config.S*obj.config.K';             %covariance update
  
        end
        
        function UpdateMulti(obj, assocWeights)
        % UpdateMulti - Performs KF update step, for multiple measurements
        %   
        %   Inputs:
        %       assoc_weights: a (1 x Nm+1) association weights matrix. The first index corresponds to the dummy measurement and
        %                       indices (2:Nm+1) correspond to measurements. Default = [0, ones(1,ObsNum)/ObsNum];
        %       LikelihoodMatrix: a (Nm x Np) likelihood matrix, where Nm is the number of measurements and Np is the number of particles.
        %
        %   (NOTE: The measurement "obj.config.y" needs to be updated, when necessary, before calling this method) 
        %   
        %   Usage:
        %       (pf.config.y = y_new; % y_new is the new measurement)
        %       pf.Update(); 
        %
        %   See also ParticleFilterX, Predict, Iterate, Smooth, resample.
            ObsNum = size(obj.config.y,2);  
            ObsDim = size(obj.config.y,1); 
            
            if(~ObsNum)
                warning('[KF] No measurements have been supplied to update track! Skipping Update step...');
                obj.config.x = obj.config.x_pred;
                obj.config.P = obj.config.P_pred;
                return;
            end
            
            if(~exist('assocWeights','var'))
                warning('[KF] No association weights have been supplied to update track! Applying default "assocWeights = [0, ones(1,ObsNum)/ObsNum];"...');
                assocWeights = [0, ones(1,ObsNum)/ObsNum]; % (1 x Nm+1)
            end
            
            % Compute Kalman gain
            innov_err      = obj.config.y - obj.config.y_pred(:,ones(1,ObsNum)); % error (innovation) for each sample
            obj.config.K   = obj.config.P_pred*obj.obs_model.config.h(obj.config.k)'/obj.config.S;  

            % update
            %Pc              = (eye(size(obj.config.x,1)) - obj.config.K*obj.obs_model.config.h(obj.config.k))*obj.config.P_pred;
            Pc              = obj.config.P_pred - obj.config.K*obj.config.S*obj.config.K';
            tot_innov_err   = innov_err*assocWeights(2:end)';
            Pgag            = obj.config.K*((innov_err.*assocWeights(ones(ObsDim,1),2:end))*innov_err' - tot_innov_err*tot_innov_err')*obj.config.K';
            
            obj.config.x    = obj.config.x_pred + obj.config.K*tot_innov_err;  
            obj.config.P    = assocWeights(1)*obj.config.P_pred + (1-assocWeights(1))*Pc + Pgag;
        end
        
        function Iterate(obj)
        % Iterate - Performs a complete UKF iteration (Predict & Update)
        %   
        %   Inputs:
        %       N/A 
        %   (NOTE: The time index/interval "obj.config.k" and measurement "obj.config.y" need to be updated, when necessary, before calling this method) 
        %   
        %   Usage:
        %       (ukf.config.k = 1; % 1 sec)
        %       (ukf.config.y = y_new; % y_new is the new measurement)
        %       ukf.Iterate();
        %
        %   See also UKalmanFilterX, Predict, Update, Smooth.
        
           % Call SuperClass method
            Iterate@KalmanFilterX(obj);
        end
        
        function smoothed_estimates = Smooth(obj, filtered_estimates)
        % Smooth - Performs UKF smoothing on a provided set of estimates
        %           (Based on [1])
        %   
        %   Inputs:
        %       filtered_estimates: a (1 x N) cell array, where N is the total filter iterations and each cell is a copy of obj.config after each iteration
        %   
        %   Outputs:
        %       smoothed_estimates: a copy of the input (1 x N) cell array filtered_estimates, where the .x and .P fields have been replaced with the smoothed estimates   
        %
        %   (Virtual inputs at each iteration)        
        %           -> filtered_estimates{k}.x          : Filtered state mean estimate at timestep k
        %           -> filtered_estimates{k}.P          : Filtered state covariance estimate at each timestep
        %           -> filtered_estimates{k+1}.x_pred   : Predicted state at timestep k+1
        %           -> filtered_estimates{k+1}.P_pred   : Predicted covariance at timestep k+1
        %           -> smoothed_estimates{k+1}.x        : Smoothed state mean estimate at timestep k+1
        %           -> smoothed_estimates{k+1}.P        : Smoothed state covariance estimate at timestep k+1 
        %       where, smoothed_estimates{N} = filtered_estimates{N} on initialisation
        %
        %   (NOTE: The filtered_estimates array can be accumulated by running "filtered_estimates{k} = ukf.config" after each iteration of the filter recursion) 
        %   
        %   Usage:
        %       ukf.Smooth(filtered_estimates);
        %
        %   [1] S. S�rkk�, "Unscented Rauch--Tung--Striebel Smoother," in IEEE Transactions on Automatic Control, vol. 53, no. 3, pp. 845-849, April 2008.
        %
        %   See also UKalmanFilterX, Predict, Update, Iterate.
        
            
            % Allocate memory
            N                           = length(filtered_estimates);
            smoothed_estimates          = cell(1,N);
            smoothed_estimates{N}       = filtered_estimates{N}; 
            
            % Perform Rauch�Tung�Striebel Backward Recursion
            for k = N-1:-1:1
                
                nx = numel(obj.config.x);       % State dims
                nw = nx;                        % State noise dims

                % Parameters for the UKF
                na = nx + nw;              % Augmented state dims

                % Augment state and covariance
                xa = [filtered_estimates{k}.x; zeros(nw,1)]; % x^a_{k-1} = [x_k-1 E[w]]
                Pa = blkdiag(filtered_estimates{k}.P, obj.dyn_model.config.Q(obj.config.k));

                % Scaling parameters and sigma-points
                [Si,flag] = chol((na + obj.config.lambda)*Pa, 'lower');
                if flag ~= 0
                    SP = nearestSPD((na + obj.config.lambda)*Pa); % Ensure Pa_km1 is positive semi-definite matrix
                    Si = chol(SP, 'lower');
                end

                % Form Augmented Sigma points
                Xa = zeros(na,2*na+1);
                Xa(:,1) = xa;
                Xa(:,2:na+1) = xa*ones(1,na) + Si(:,1:na);
                Xa(:,na+2:2*na+1) = xa*ones(1,na) - Si(:,1:na);

                % Compute Sigma Weights
                Wm = [obj.config.lambda/(na + obj.config.lambda) repmat(1/(2*(na + obj.config.lambda)),1,2*na)];
                Wc = Wm;
                Wc(1,1) = Wm(1,1) + (1 -obj.config.alpha^2 + obj.config.beta);

                % Unscented Tranform
                [xa_pred, Xa_pred, Pa_pred] = obj.UnscentedTransform( @(X)obj.dyn_model.sys(obj.config.k,X), Xa(1:nx,:), Wm, Wc, Xa(nx+1:end,:));
                
                smoothed_estimates{k}.C     = (Xa(1:nx,:)-filtered_estimates{k}.x)*diag(Wc)*(Xa_pred-xa_pred)'/Pa_pred;%(filtered_estimates{k}.P * filtered_estimates{k+1}.Fjac' / filtered_estimates{k+1}.P_pred;
                smoothed_estimates{k}.x     = filtered_estimates{k}.x + smoothed_estimates{k}.C * (smoothed_estimates{k+1}.x - filtered_estimates{k+1}.x_pred);
                smoothed_estimates{k}.P     = filtered_estimates{k}.P + smoothed_estimates{k}.C * (smoothed_estimates{k+1}.P - filtered_estimates{k+1}.P_pred) * smoothed_estimates{k}.C';                            
            end
        end
        
        function [x_pred,X_pred,P_pred, P1] = UnscentedTransform(obj,f,X,Wm,Wc,R)
                  
            % Propagate sigma points
            X_pred = f(X) + R;
            
            % Transformed mean
            x_pred = sum(Wm.*X_pred,2); % Weighted average
            
            % Transformed variance and covariance
            P1 = (X_pred-x_pred);       % Variance
            P_pred = P1*diag(Wc)*P1';   % Weighted covariance 
        end

    end
end