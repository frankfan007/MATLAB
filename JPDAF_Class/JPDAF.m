classdef JPDAF <handle
% =====================================================================================
% Parameters:
% Par: structure with the following fields
%       
%       * Variables
%       -------------------
%       .GroundTruth      = ground truth data
%                           (optional if DataList is provided)
%       .DataGenerator    = Data generator class instance
%                           (optional if DataList is provided)
%       .DataList         = all available observations 
%                           (optional if GroundTruth is provided)
%       .TrackList        = A list of initiated targets (optional)
%       .TrackNum         = Number of targets to be generated
%                           (only applies when DataList is not provided)
%       .Filter           = Underlying filter class instance to be used
%                           (KF, EKF, UKF or PF - only used if TrackList is not provided)
%       .lambda           = False alarm density
%       .PD               = Probability of detection
%       .PG               = PG
%       .GateLevel        = GateLevel (Based on mahal. distance)
%       .InitDelMethod    = Track management method
%       .Pbirth           = Probability of new target birth
%       .Pdeath           = Probability of target death
%       .SimIter          = Number of timesteps to allow simulation for

    properties
        config
    end
    
    methods
        function obj = JPDAF(prop)
            % Validate .Filter ~~~~~~~~~~~~~~~~~~~~~~>
            if ~isfield(prop,'Filter')&&~isfield(prop,'TrackList')
                error('Base Filter class instance (config.Filter) has not been provided.. Please instantiate the desired filter (KF, EKF, UKF or PF) and include it as an argument! \n');             
            elseif ~isfield(prop,'TrackList')
                if(isa(prop.Filter,'ParticleFilterMin2'))
                    prop.FilterType = 'PF';
                elseif(isa(prop.Filter,'KalmanFilter_new'))
                    prop.FilterType = 'KF';
                elseif(isa(prop.Filter,'EKalmanFilter'))
                    prop.FilterType = 'UKF';
                elseif(isa(prop.Filter,'UKalmanFilter'))
                    prop.FilterType = 'EKF';
                else
                    error('Base Filter class instance (config.Filter) is invalid.. Please instantiate the desired filter (KF, EKF, UKF or PF) and include it as an argument! \n');
                end
            end
            % ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~>
            
            % Validate .DataList, .GroundTruth ~~~~~~>
            if ~isfield(prop,'DataList') && ~isfield(prop,'GroundTruth')
                error('No DataList and no Ground Truth have been supplied. please provide one of the two in order to proceed.\nNOTE: if only Ground Truth is supplied, then a DataGenerator instance needs to also be provided.');
            elseif ~isfield(prop,'DataList') && ~isfield(prop,'DataGenerator')
                error('If only Ground Truth is supplied, then a DataGenerator instance needs to also be provided such that a simulated DataList can be produced.');    
            elseif ~isfield(prop,'DataList')
                prop.DataList = prop.DataGenerator.genDataList();
            end
            % ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~>
            
            % TrackList ~~~~~~>
            if isfield(prop,'TrackList')
                prop.TrackNum = size(prop.TrackList,2);
            end
            % ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~>
            
            
            % Validate .PD, .GateLevel, .Pbirth, .Pdeath, .SimIter ~~~~~~>
            if ~isfield(prop,'PD') || ~isfield(prop,'PG') || ~isfield(prop,'GateLevel') || ~isfield(prop,'Pbirth') || ~isfield(prop,'Pdeath') || ~isfield(prop,'SimIter')
                error('One of the following has not been provide: PD, PG, GateLevel, Pbirth, Pdeath, SimIter!');
            end
            % ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~>
            
            obj.config = prop;
      
        end
        
        function Predict(obj)
            obj.config.TrackNum = size( obj.config.TrackList,2);
            if(~isempty(obj.config.TrackList))
                
                if(isa(obj.config.TrackList{1}.TrackObj,'ParticleFilterMin2')) 

                    % Predict all targets and evaluate the validation matrix
                    obj.config.ValidationMatrix = zeros(obj.config.TrackNum, size(obj.config.DataList,2)); 
                    tot_gate_area = 0;
                    for t = 1:obj.config.TrackNum
                        %obj.config.TrackList{t}.TrackObj.pf.k = i;
                        obj.config.TrackList{t}.TrackObj.pf.z = obj.config.DataList;
                        obj.config.TrackList{t}.TrackObj.pf = obj.config.TrackList{t}.TrackObj.PredictMulti(obj.config.TrackList{t}.TrackObj.pf);
                        obj.config.ValidationMatrix(t,:) = obj.config.TrackList{t}.TrackObj.pf.Validation_matrix;
                        tot_gate_area = tot_gate_area + obj.config.TrackList{t}.TrackObj.pf.V_k;
                    end

                    PointNum = size(obj.config.ValidationMatrix,2);

                    % Compute New Track/False Alarm density
                    obj.config.bettaNTFA = sum(obj.config.ValidationMatrix(:))/tot_gate_area;
                    if(obj.config.bettaNTFA==0)
                        obj.config.bettaNTFA=1
                    end
                    
                    % Compute Association Likelihoods 
                    Li = zeros(obj.config.TrackNum, PointNum);
                    for j=1:obj.config.TrackNum
                        % Get valid measurement data indices
                        ValidDataInd = find(obj.config.TrackList{j}.TrackObj.pf.Validation_matrix(1,:));
                        for i=1:size(ValidDataInd,2)
                            Li(j, ValidDataInd(1,i)) = obj.config.TrackList{j}.TrackObj.pf.Li(1,i)'*obj.config.PD*obj.config.PG;
                        end
                    end
                    obj.config.Li = Li;

                    % Get all clusters
                    obj.FormClusters();

                    % Perform data association
                    % Create Hypothesis net for each cluster
                    NetList = [];
                    betta = zeros(obj.config.TrackNum, PointNum+1);
                    for c=1:size(obj.config.ClusterList,2)
                        Cluster = obj.config.ClusterList{c};
                        ClustMeasIndList = Cluster.MeasIndList;
                        ClustTrackIndList = Cluster.TrackIndList;
                        ClustLi = [ones(size(obj.config.Li(ClustTrackIndList, ClustMeasIndList),1), 1)*obj.config.bettaNTFA*(1-obj.config.PD*obj.config.PG),obj.config.Li(ClustTrackIndList, ClustMeasIndList)]; 
                        NetList{c} = buildEHMnet_trans([ones(size(obj.config.ValidationMatrix(ClustTrackIndList, ClustMeasIndList),1),1), obj.config.ValidationMatrix(ClustTrackIndList, ClustMeasIndList)], ClustLi);
                        betta(ClustTrackIndList, [1, ClustMeasIndList+1]) = NetList{c}.betta;
                    end
                    obj.config.NetList = NetList;
                    obj.config.betta = betta;
                else
                    GateLevel   = 5; % 98.9% of data in gate
                    %TrackNum    = size(TrackList,2);
                    PointNum    = size(obj.config.DataList,2);
                    ObsDim      = size(obj.config.DataList,1);
                    C = pi; % volume of the 2-dimensional unit hypersphere (change for different Dim no)


                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    % variables
                    tot_gate_area = 0;

                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    % check un-initalized tracks (state 0)
                    %for i=1:TrackNum,
                    %    if TrackList{i}.TrackObj.State == Par.State_Undefined, error('Undefined Tracking object'); end;
                    %end;

                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    % find associated data
                    % init association matrix
                    DistM = ones(obj.config.TrackNum,size(obj.config.DataList,2))*1000;
                    for i=1:obj.config.TrackNum

                        % extract track coordinates and covariance
                        obj.config.TrackList{i}.TrackObj.s = obj.config.TrackList{i}.TrackObj.Predict(obj.config.TrackList{i}.TrackObj.s);
                        tot_gate_area = tot_gate_area + C*obj.config.GateLevel^(ObsDim/2)*det( obj.config.TrackList{i}.TrackObj.s.S)^(1/2);

                        % measure points
                        for j=1:PointNum

                            % distance
                            DistM(i,j)  = mahalDist(obj.config.DataList(:,j), obj.config.TrackList{i}.TrackObj.s.z_pred, obj.config.TrackList{i}.TrackObj.s.S, 2); 

                        end

                    end
                    %%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%%
                    % thresholding/gating validation
                    obj.config.ValidationMatrix = DistM < obj.config.GateLevel;
                    
                    obj.config.bettaNTFA = sum(ValidationMatrix(:))/tot_gate_area;
                end
            else
                fprintf('No tracks where found. Skipping JPDAF Predict step...\n');
                obj.config.ValidationMatrix = zeros(1, size(obj.config.DataList,2));
                obj.config.bettaNTFA = 0;
                obj.config.betta = -1; % Set betta to -1
            end
        end
        
        function Update(obj)
            if(~isempty(obj.config.TrackList))
                if(isa(obj.config.TrackList{1}.TrackObj,'ParticleFilterMin2'))
                    obj.PF_Update();
                else
                    obj.KF_Update();
                end
            else
                fprintf('No tracks where found. Skipping JPDAF Update step...\n');
            end
        end
        
        %   PF_Update                           Author: Lyudmil Vladimirov
        %   ======================================================================>
        %   Functionality: 
        %       Compute association weights (betta) and perform track
        %       update for each target, using EHM.
        %   
        %   Input: 
        %       TrackList    - List of all target tracks at time k(TrackObj's)
        %       DataList     - List of all measurements at time k
        %       ValidationMatrix    - Matrix containing all possible measurement to
        %                             track associations.
        %                             (Output from ObservationAssociation.m)
        %       bettaNTFA    - New track/False alarm density (assumed to be same)
        %   
        %   Output:
        %       TrackList    - Updated list of all target tracks
        %   
        %   Dependencies: buildEHMnet_Fast.m 
        %   ~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~~

        function PF_Update(obj)
            %% Initiate parameters
            TrackNum    = size(obj.config.TrackList,2); % Number of targets including FA
            % alpha       = 0.3;      % log likelihood forget factor
            PG          = obj.config.PG;      % probability of Gating
            PD          = obj.config.PD;      % probability of Detection
            GateLevel   = obj.config.GateLevel;
            bettaNTFA    = obj.config.bettaNTFA;
            ValidationMatrix = obj.config.ValidationMatrix;
            PointNum = size(obj.config.ValidationMatrix,1);
            TrackList = obj.config.TrackList;
            clustering  = 1;

            %% Compute weights and update each track
            for i=1:TrackNum

                cluster_id = 0;
                % Get the index of the cluster which track belongs to
                for j=1:size(obj.config.ClusterList,2)
                    Cluster = obj.config.ClusterList{j};
                    if (ismember(i, Cluster.TrackIndList)~=0)
                        cluster_id = j;
                        break;
                    end
                end

                % If target has been matched with a cluster
                %  then extract it's association prob. matrix
                if(cluster_id~=0)
                    try
                        % Get the EHM Net relating to that cluster
                        NetObj = obj.config.NetList{cluster_id};
                        %NetObj = NetList{1};
                    catch
                        disp('this');
                    end

                    DataInd      = find(obj.config.ValidationMatrix(i,:));    % Associated measurements

                    % extract measurements
                    z = obj.config.DataList(:,DataInd);

                    % Compute likelihood ratios
                   % Compute likelihood ratios
                    ClustMeasIndList=[];
                    for j=1:size(DataInd,2)
                       try
                        ClustMeasIndList(j) = unique(find(obj.config.ClusterList{cluster_id}.MeasIndList==DataInd(j)));
                       catch
                           error('f');
                       end    
                    end
                    ClustTrackInd = find(obj.config.ClusterList{cluster_id}.TrackIndList==i); % T1 is the false alarm

                    % Extract betta for target
            %         if(isempty(NetObj.betta_trans(ClustTrackInd, find(NetObj.betta_trans(ClustTrackInd, :)))))
            %             disp('error');
            %         end
                    obj.config.TrackList{i}.TrackObj.pf.ValidDataInd;
                    obj.config.TrackList{i}.TrackObj.pf.betta = [obj.config.betta(i,1), obj.config.betta(i,DataInd+1)];% [NetObj.betta(ClustTrackInd,1), NetObj.betta(ClustTrackInd, ClustMeasIndList+1)];
                else
                    % Else if target was not matched with any clusters, it means it was
                    % also not matched with any measurements and thus only the "dummy"
                    % measurement association is possible (i.e. betta = [1]);
                    obj.config.TrackList{i}.TrackObj.pf.betta = 1;
                end

                %------------------------------------------------
                % update
                obj.config.TrackList{i}.TrackObj.pf = obj.config.TrackList{i}.TrackObj.UpdateMulti(obj.config.TrackList{i}.TrackObj.pf);
            end    % track loop
        end
        
        function ClusterList = FormClusters(obj)
            %% Initiate parameters
            TrackNum    = size(obj.config.TrackList,2); % Number of targets including FA
            % alpha       = 0.3;      % log likelihood forget factor
            PG          = obj.config.PG;      % probability of Gating
            PD          = obj.config.PD;      % probability of Detection
            GateLevel   = obj.config.GateLevel;
            bettaNTFA    = obj.config.bettaNTFA;
            ValidationMatrix = obj.config.ValidationMatrix;
            PointNum = size(obj.config.ValidationMatrix,2);
            TrackList = obj.config.TrackList;
            clustering  = 1;

            %% Form clusters of tracks sharing measurements
            clusters = {};
            if(clustering)
                if(isfield(obj.config, 'pdaf'))
                    % Do nothing
                else
                    % Measurement Clustering
                    for i=1:TrackNum % Iterate over all tracks 
                        matched =[];
                        temp_clust = find(ValidationMatrix(i,:)); % Extract associated measurements

                        % If track matched with any measurements
                        if (~isempty(temp_clust))   
                            % Check if matched measurements are members of any clusters
                            for j=1:size(clusters,2)
                                a = ismember(temp_clust, cell2mat(clusters(1,j)));
                                if (ismember(1,a)~=0)
                                    matched = [matched, j]; % Store matched cluster ids
                                end   
                            end

                            % If only matched with a single cluster, join.
                            if(size(matched,2)==1) 
                                clusters{1,matched(1)}=union(cell2mat(clusters(1,matched(1))), temp_clust);
                            elseif (size(matched,2)>1) % If matched with more that one clusters
                                matched = sort(matched); % Sort cluster ids
                                % Start from last cluster, joining each one with the previous
                                %   and removing the former.  
                                for match_ind = size(matched,2)-1:-1:1
                                    clusters{1,matched(match_ind)}=union(cell2mat(clusters(1,matched(match_ind))), cell2mat(clusters(1,matched(match_ind+1))));
                                    clusters(:,matched(match_ind+1))=[];
                                end
                                % Finally, join with associated track.
                                clusters{1,matched(match_ind)}=union(cell2mat(clusters(1,matched(match_ind))), temp_clust);
                            else % If not matched with any cluster, then create a new one.
                                clusters{1,size(clusters,2)+1} = temp_clust;
                            end
                         end
                    end
                end
            else
                % Measurement Clustering
                for i=1:TrackNum % Iterate over all tracks (including dummy)

                    temp_clust = find(ValidationMatrix(i,:)); % Extract associated tracks

                    % If measurement matched with any tracks
                    if (~isempty(temp_clust))
                        if(~isempty(clusters))
                            clusters{1,1}= union(clusters{1,1}, temp_clust);
                        else
                           clusters{1,1}= temp_clust; 
                        end
                    end
                end
            end

            % Build ClusterList
            ClusterList = [];
            ClusterObj.MeasIndList = [];
            ClusterObj.TrackIndList = [];
            if(isfield(obj.config, 'pdaf'))
                for i=1:TrackNum
                    ClusterList{i} = ClusterObj;
                    ClusterList{i}.MeasIndList = find(ValidationMatrix(i,:));
                    ClusterList{i}.TrackIndList = i;
                end
            else
                for c=1:size(clusters,2)
                    ClusterList{c} = ClusterObj;
                    ClusterList{c}.MeasIndList = unique(clusters{1,c}(:)');

                    % If we are currently processing the cluster of unassociated tracks 
                    if(isempty(ClusterList{c}.MeasIndList))
                        ClusterList{c}.TrackIndList = unique(union(ClusterList{c}.TrackIndList, find(all(ValidationMatrix==0))));
                    else
                        for i = 1:size(ClusterList{c}.MeasIndList,2) 
                            ClusterList{c}.TrackIndList = unique(union(ClusterList{c}.TrackIndList, find(ValidationMatrix(:,ClusterList{c}.MeasIndList(i)))));
                        end
                    end
                end
            end
            obj.config.ClusterList = ClusterList;
        end
        
        function Par =  TrackInitConfDel(~,Par)
            for t = 1:config.TrackNum
                if(config.TrackList{t}.TrackObj.pf.ExistProb>0.1)
                    TrackList{end} = config.TrackList{t};
                end
            end
            TrackNum = size(TrackList,2);

            invalidDataInd = find((sum(config.ValidationMatrix,1)==0));
            % Process search track
            if(config.pf_search.pf.ExistProb>0.9)
                disp('Search Track Exist prob:');
                config.pf_search.pf.z = config.DataList(:, invalidDataInd);
                config.pf_search.pf = config.pf_search.PredictSearch(config.pf_search.pf);
                config.pf_search.pf = config.pf_search.UpdateSearch(config.pf_search.pf);

                if(config.pf_search.pf.ExistProb>0.9)
                    % Promote new track
                    TrackNum = TrackNum + 1;
                    TrackList{TrackNum}.TrackObj = config.pf_search;

                    % Create new PF search track
                    nx = 4;      % number of state dims
                    nu = 4;      % size of the vector of process noise
                    nv = 2;      % size of the vector of observation noise
                    q  = 0.01;   % process noise density (std)
                    r  = 0.3;    % observation noise density (std)
                    % Process equation x[k] = sys(k, x[k-1], u[k]);
                    sys_cch = @(k, xkm1, uk) [xkm1(1,:)+1*xkm1(3,:).*cos(xkm1(4,:)); xkm1(2,:)+1*xkm1(3,:).*sin(xkm1(4,:)); xkm1(3,:)+ uk(:,3)'; xkm1(4,:) + uk(:,4)'];
                    % PDF of process noise generator function
                    gen_sys_noise_cch = @(u) mvnrnd(zeros(size(u,2), nu), diag([0,0,q^2,0.16^2])); 
                    % Observation equation y[k] = obs(k, x[k], v[k]);
                    obs = @(k, xk, vk) [xk(1)+vk(1); xk(2)+vk(2)];                  % (returns column vector)
                    % PDF of observation noise and noise generator function
                    sigma_v = r;
                    cov_v = sigma_v^2*eye(nv);
                    p_obs_noise   = @(v) mvnpdf(v, zeros(1, nv), cov_v);
                    % Observation likelihood PDF p(y[k] | x[k])
                    % (under the suposition of additive process noise)
                    p_yk_given_xk = @(k, yk, xk) p_obs_noise((yk - obs(k, xk, zeros(1, nv)))');
                    % Assign PF parameter values
                    pf.k               = 1;                   % initial iteration number
                    pf.Np              = 10000;                 % number of particles
                    pf.particles       = zeros(5, pf.Np); % particles
                    pf.resampling_strategy = 'systematic_resampling';
                    pf.sys = sys_cch;
                    pf.particles = zeros(nx, pf.Np); % particles
                    pf.obs = p_yk_given_xk;
                    pf.obs_model = @(xk) [xk(1,:); xk(2,:)];
                    pf.R = cov_v;
                    pf.clutter_flag = 1;
                    pf.multi_flag = 0;
                    pf.sys_noise = gen_sys_noise_cch;
                    pf.gen_x0 = @(Np) [10*rand(Np,1),10*rand(Np,1), mvnrnd(zeros(Np,1), 2*sigma_v^2), 2*pi*rand(Np,1)];
                    %pf.xhk = [s.x_init(1,i),s.x_init(2,i),0,0]';
                    pf.ExistProb = 0.5;
                    config.pf_search = ParticleFilterMin2(pf);

                    disp('Promoted one track');
                end
            else
                disp('Search Track Exist prob:');
                config.pf_search.pf.z = config.DataList(:, invalidDataInd);
                config.pf_search.pf = config.pf_search.PredictSearch(config.pf_search.pf);
                config.pf_search.pf = config.pf_search.UpdateSearch(config.pf_search.pf);;
                if(config.pf_search.pf.ExistProb<0.1)
                    % Reset the search track
                    pf.gen_x0 = @(Np) [10*rand(Np,1),10*rand(Np,1), mvnrnd(zeros(Np,1), 2*sigma_v^2), 2*pi*rand(Np,1)];
                    %pf.xhk = [s.x_init(1,i),s.x_init(2,i),0,0]';
                    pf.ExistProb = 0.5;
                    pf_search = ParticleFilterMin2(pf);
                    pf_search.pf.multi_flag = 0;
                end

            end
        end
    end
    
    methods (Static)
        function D=mahalDist(x, m, C, use_log)
        % p=gaussian_prob(x, m, C, use_log)
        %
        % Evaluate the multi-variate density with mean vector m and covariance
        % matrix C for the input vector x.
        % Vectorized version: Here X is a matrix of column vectors, and p is 
        % a vector of probabilities for each vector.

            if nargin<4, use_log = 0; end

            d   = length(m);

            if size(x,1)~=d
               x=x';
            end
            N       = size(x,2);

            m       = m(:);
            M       = m*ones(1,N);
            denom   = (2*pi)^(d/2)*sqrt(abs(det(C)));
            invC    = inv(C);
            mahal   = sum(((x-M)'*invC).*(x-M)',2);   % Chris Bregler's trick

            switch use_log,
            case 2,
              D     = mahal;
            case 1,
              D     = -0.5*mahal - log(denom);
            case 0,
              numer = exp(-0.5*mahal);
              D     = numer/denom;
            otherwise
                error('Unsupported log type')
            end
        end
    end
end