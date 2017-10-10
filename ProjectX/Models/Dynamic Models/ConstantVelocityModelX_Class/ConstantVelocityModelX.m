classdef ConstantVelocityModelX <  matlab.mixin.Copyable % Handle class with copy functionality
    % ConstantVelocityModelX class
    %
    % Summary of ConstantVelocityModel
    % This is a class implementation of a linear-Gaussian Constant Velocity Dynamic Model.
    %
    % The model is described by the following SDEs:
    %
    %   dx = s_x*dt                    | Position on X-axis (m)
    %   dy = s_y*dt                    | Position on Y axis (m)
    %   ds = q*dW_t,  W_t~N(0,q^2)     | Speed on X-axis    (m/s)
    %   dh = q*dB_t,  B_t~N(0,q^2)     | Speed on Y-axis    (m/s)
    %
    % ConstantHeadingModelX Properties:
    %    - config   = structure with fields:
    %       .dim             = dimensionality (1-3, default 2)
    %       .q               = Process noise diffusion coefficient (default 0.01 m/s^2)
    %       .f(Dt,~)         = Time-variant process transition function handle f(x_k|x_{k-1}), returns matrix (Defined internally, but can be overloaded)
    %    	.Q(Dt)           = Time-variant process noise covariance function handle, returns (nx x nx) matrix (Defined internally, but can be overloaded)
    %
    % ConstantVelocityModelX Methods:
    %    sys        - State vector process transition function f(x_{k-1},w_k) 
    %    sys_cov    - State covariance process transition function f(P_{k-1},Q_k)
    %    sys_noise  - Process noise sample generator 
    %    eval       - Evaluates the probability p(x_k|x_{k-1}) = N(x_k; x_{k-1}, Q) of a set of new states, given a set of (particle) state vectors  
  
    properties
        config
    end
    
    methods
        function obj = ConstantVelocityModelX(config)
            % Validate .dim
            if ~isfield(config,'dim')
                fprintf('[CVModel] Model dimensionality has not been specified... Applying default setting "dim = 2"..\n');
                config.dim = 2;
            end
            
            % Validate .F
            if ~isfield(config,'F')
                switch(config.dim)
                    case(1)
                        config.f = @(Dt,~) [1 Dt;
                                            0 1]; 
                                    
                        fprintf('[CVModel] Transition matrix missing... Applying default setting "F = @(Dt) [1 Dt; 0 1]"..\n');
                    case(2)
                        config.f = @(Dt,~) [1 0 Dt 0;
                                            0 1 0 Dt;
                                            0 0 1 0;
                                            0 0 0 1];
                        fprintf('[CVModel] Transition matrix missing... Applying default setting "F = @(Dt) [1 0 Dt 0; 0 1 0 Dt; 0 0 1 0; 0 0 0 1]"..\n');
                    case(3)
                        config.f = @(Dt,~) [1 0 0 Dt 0 0;
                                            0 1 0 0 Dt 0;
                                            0 0 1 0 0 Dt;
                                            0 0 0 1 0 0;
                                            0 0 0 0 1 0;
                                            0 0 0 0 0 1];
                        fprintf('[CVModel] Transition matrix missing... Applying default setting "F = @(Dt) [1 0 0 Dt 0 0; 0 1 0 0 Dt 0; 0 0 1 0 0 Dt; 0 0 0 1 0 0; 0 0 0 0 1 0; 0 0 0 0 0 1]"..\n');
                end
            end
            
            % Validate .q
            if ~isfield(config,'q')
                config.q = 0.01;
                fprintf('[CVModel] Process noise diffusion coefficient missing... Applying default setting "q = 0.01"..\n');
            end
            
            % Validate .Q
            if ~isfield(config,'Q')
                switch(config.dim)
                    case(1)
                        config.Q = @(Dt) [Dt^3/3 Dt^2/2;
                                          Dt^2/2 Dt]; 
                                    
                        fprintf('[CVModel] Process noise covariance missing... Applying default setting "Q = @(Dt) [Dt^3/3 Dt^2/2; Dt^2/2 Dt]"..\n');
                    case(2)
                        config.Q = @(Dt) [Dt^3/3, 0, Dt^2/2, 0;
                                          0, Dt^3/3, 0, Dt^2/2; 
                                          Dt^2/2, 0, Dt, 0;
                                          0, Dt^2/2, 0, Dt]*config.q;
                        fprintf('[CVModel] Process noise covariance missing... Applying default setting "Q = @(Dt) [Dt^3/3, 0, Dt^2/2, 0; 0, Dt^3/3, 0, Dt^2/2; Dt^2/2, 0, Dt, 0; 0, Dt^2/2, 0, Dt]*q"..\n');
                    case(3)
                        config.Q = @(Dt) [Dt^3/3 0 0 Dt^2/2 0 0;
                                          0 Dt^3/3 0 0 Dt^2/2 0;
                                          0 0 Dt^3/3 0 0 Dt^2/2;
                                          Dt^2/2 0 0 Dt 0 0;
                                          0 Dt^2/2 0 0 Dt 0;
                                          0 0 Dt^2/2 0 0 Dt]*config.q;
                        fprintf('[CVModel] Process noise covariance missing... Applying default setting "Q = @(Dt) [Dt^3/3 0 0 Dt^2/2 0 0; 0 Dt^3/3 0 0 Dt^2/2 0; 0 0 Dt^3/3 0 0 Dt^2/2; Dt^2/2 0 0 Dt 0 0; 0 Dt^2/2 0 0 Dt 0; 0 0 Dt^2/2 0 0 Dt]*q"..\n');
                end
            end
            
            obj.config = config;
      
        end
        
        function x_k = sys(obj, Dt, x_km1, w_k)
        % sys - State vector process transition function f(x_{k-1},w_k) 
        %
        %   Inputs:
        %       Dt : Time interval since last timestep (in seconds)
        %       x_km1: a (nx x Ns) matrix of Ns state vectors from time k-1, where nx is the dimensionality of the state
        %       w_k: a (nx x Ns) matrix Ns of process noise vectors, corresponding to the state vectors x_km1. (Optional)  
        %
        %   Outputs:
        %       x_k: a (nx x Ns) matrix of Ns state vectors, which have been propagated through the dynamic model   
        %
        %   Usage:
        %   x_k = cv.sys(Dt, x_km1) propagates the (nx x Ns) state vector x_km1 through the dynamic model for time Dt, without the inclusion of process noise
        %   p_k = cv.sys(Dt, p_km1, cv.sys_noise(Ns)) propagates the (nx x Ns) particle matrix p_km1 through the dynamic model for time Dt, including randomly generated process noise by using the ConstantVelocityModel.sys_noise function.
        %   s_k = cv.sys(Dt, s_km1, wk) propagates the (nx x Ns) sigma-point matrix s_km1 through the dynamic model for time Dt, including an externally computed (nx x Ns) process noise matrik wk 
        %
        %   See also sys_cov, sys_noise.
        
            % Get dimensions
            Ns = size(x_km1,2);
            nx = size(x_km1,1);
            
            % 
            if(~exist('w_k','var'))
                w_k = zeros(nx,Ns);
            end
            
            x_k = obj.config.f(Dt)*x_km1 + w_k;
        end
        
        function P_k = sys_cov(obj, Dt, P_km1, Q_k)
        % sys_cov - State covariance process transition function f(P_{k-1},Q_k) 
        %
        %   Inputs:
        %       Dt : Time interval since last timestep (in seconds)
        %       P_km1: a (nx x nx) state covariance matrix, where nx is the dimensionality of the state
        %       Q_k: a (nx x nx) process noise covariance matrix. (Optional)  
        %
        %   Outputs:
        %       P_k: a (nx x nx) state covariance, which have been propagated through the dynamic model   
        %
        %   Usage:
        %   P_k = cv.sys_cov(Dt, P_km1) propagates the (nx x nx) state covariance P_km1 through the dynamic model for time Dt, without the inclusion of process noise
        %   P_k = cv.sys_cov(Dt, P_km1, Q_k) propagates the (nx x nx) state covariance P_km1 through the dynamic model for time Dt, including a process noise covariance Q_k 
        %
        %   See also sys, sys_noise.
        
            % Get dimensions
            nx = size(P_km1,1);
        
            if(~exist('Q_k','var'))
                Q_k = obj.config.Q(Dt);
            elseif(strcmp(Q_k, 'false'))
                Q_k = zeros(nx);
            end
            P_k = obj.config.f(Dt)*P_km1*obj.config.f(Dt)' + Q_k;
        end
        
        function w_k = sys_noise(obj, Dt, Ns)
        % sys_noise - Process noise sample generator 
        %
        %   Inputs:
        %       Dt : Time interval since last timestep (in seconds)
        %       Ns : The number samples to be generated (Optional, default is 1)  
        %
        %   Outputs:
        %       w_k: a (nx x Ns) matrix of Ns process noise samples, where nx is the dimensionality of the state   
        %
        %   Usage:
        %   w_k = cv.sys_noise(Dt) generates a (nx x 1) noise vector
        %   w_k = cv.sys_noise(Dt, Ns) generates a (nx x Ns) noise vector 
        %
        %   See also sys, sys_cov.
            if(~exist('Ns', 'var'))
                Ns = 1;
            end
        
            % Get dimensions
            nx = 2*obj.config.dim;
        
            w_k = mvnrnd(zeros(nx,Ns)',obj.config.Q(Dt))';
        end
        
        function p = eval(obj, Dt, x_k, x_km1)
        % eval - Evaluates the probability p(x_k|x_{k-1}) = N(x_k; x_{k-1}, Q) of a set of new states, given a set of (particle) state vectors  
        % 
        %   Inputs:
        %       Dt: time index/interval
        %       x_k : a (nx x Np) matrix of Np new state vectors, where nx is the dimensionality of the state
        %       x_km1 : a (nx x Ns) matrix of Ns old state vectors, where nx is the dimensionality of the state
        %
        %   Outputs:
        %       p: a (Np x Ns) matrix of probabilities p(x_k|x_{k-1})    
        %
        %   Usage:
        %   p = eval(obj, Dt, x_k, x_km1) Evaluates and produces a (Np x Ns) probability matrix.
        %
        %   See also obs, obs_cov, obs_noise, sample.
        
            p = zeros(size(x_k,2), size(x_km1,2));
            if(issymmetric(obj.config.Q(Dt)) && size(x_km1,2)>size(x_k,2))
                % If R is symmetric and the number of state vectors is higher than the number of measurements,
                %   then evaluate N(x_km1; x_k, R) = N(x_k; x_km1, R) to increase speed
                for i=1:size(x_k,2)
                    p(i,:) = mvnpdf(x_km1', x_k(:,i)', obj.config.Q(Dt))';
                end
            else
                for i=1:size(x_km1,2)
                    p(:,i) = mvnpdf(x_k', x_km1(:,i)', obj.config.Q(Dt))';  
                end
             end
                        
        end
        
    end
end