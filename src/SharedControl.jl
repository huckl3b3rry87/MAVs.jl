module SharedControl

using NLOptControl
using VehicleModels
using JuMP
using DataFrames
using Parameters

include("CaseModule.jl")
using .CaseModule

export
      initializeSharedControl,
      sharedControl,
      getPlantData,
      sendOptData,
      ExternalModel

type ExternalModel  # communication
  s1
  s2
  status   # to pass result of optimization to Matlab
  runJulia # a Bool (in Int form) to indicate to run julia comming from Matlab
  numObs   # number of obstacles
  SA       # drivers steering angle
  UX       # vehicle speed
  X_Obs
  Y_Obs
  A
  B
end

function ExternalModel()
  ExternalModel(Any,
                Any,
                1.0,
                1,
                3,
                0.0,
                0.0,
                [],
                [],
                [],
                [])
end


"""
mdl,n,r,params = initializeSharedControl(c);
--------------------------------------------------------------------------------------\n
Author: Huckleberry Febbo, Graduate Student, University of Michigan
Date Create: 1/27/2017, Last Modified: 4/4/2017 \n
--------------------------------------------------------------------------------------\n
"""
function initializeSharedControl(c)

    pa=Vpara(x_min=c.m.Xlims[1],x_max=c.m.Xlims[2],y_min=c.m.Ylims[1],y_max=c.m.Ylims[2],Fz_min=1.0);
    n=NLOpt(); @unpack_Vpara pa;

    if c.m.model==:ThreeDOFv1
      error("not set up for this right now...")
      XF = [NaN, NaN,  NaN,  NaN, NaN];
      XL = [x_min, y_min, NaN, NaN, psi_min];
      XU = [x_max, y_max, NaN, NaN, psi_max];
      CL = [sa_min]; CU = [sa_max];
      n = define(n,stateEquations=ThreeDOFv1,numStates=5,numControls=1,X0=c.m.X0,XF=XF,XL=XL,XU=XU,CL=CL,CU=CU);

      # variable names
      names = [:x,:y,:v,:r,:psi];
      descriptions = ["X (m)","Y (m)","Lateral Velocity (m/s)","Yaw Rate (rad/s)","Yaw Angle (rad)"];
      stateNames(n,names,descriptions)
      names = [:sa];
      descriptions = ["Steering Angle (rad)"];
      controlNames(n,names,descriptions);
    elseif c.m.model==:ThreeDOFv2
      XF=[  NaN, NaN,   NaN, NaN,     NaN,    NaN,    NaN, NaN];
      XL=[x_min, y_min, NaN, NaN, psi_min, sa_min, c.m.UX, 0.0];
      XU=[x_max, y_max, NaN, NaN, psi_max, sa_max, c.m.UX, 0.0];
      CL = [sr_min, 0.0]; CU = [sr_max, 0.0];
      n = define(n,stateEquations=ThreeDOFv2,numStates=8,numControls=2,X0=c.m.X0,XF=XF,XL=XL,XU=XU,CL=CL,CU=CU);

      # variable names
               # 1  2  3  4  5    6   7   8
      names = [:x,:y,:v,:r,:psi,:sa,:ux,:ax];
      descriptions = ["X (m)","Y (m)","Lateral Velocity (m/s)", "Yaw Rate (rad/s)","Yaw Angle (rad)", "Steering Angle (rad)", "Longitudinal Velocity (m/s)", "Longitudinal Acceleration (m/s^2)"];
      stateNames(n,names,descriptions);
               # 1    2
      names = [:sr,:jx];
      descriptions = ["Steering Rate (rad/s)","Longitudinal Jerk (m/s^3)"];
      controlNames(n,names,descriptions);
    else
      error("\n set c.m.model \n")
    end

    # configure problem
    n = configure(n,Ni=c.m.Ni,Nck=c.m.Nck;(:integrationMethod => :ps),(:integrationScheme => :lgrExplicit),(:finalTimeDV => false),(:tf => c.m.tp))
    mpcParams(n,c);
    mdl=defineSolver(n,c);

    # define tolerances
    if c.m.model==:ThreeDOFv1
      XF_tol=[NaN,NaN,NaN,NaN,NaN];
      X0_tol=[0.05,0.05,0.005,0.05,0.01];
      defineTolerances(n;X0_tol=X0_tol,XF_tol=XF_tol);
    elseif c.m.model==:ThreeDOFv2
      XF_tol=[NaN,NaN,NaN,NaN,NaN,NaN,NaN,NaN];
      X0_tol=[0.05,0.05,0.005,0.05,0.01,0.001,NaN,NaN];  # TODO BE CAREFUL HERE!!
      defineTolerances(n;X0_tol=X0_tol,XF_tol=XF_tol);
    else
      error("\n set c.m.model \n")
    end

    # add parameters
    @NLparameter(mdl, ux_param==c.m.UX); # inital vehicle speed
    @NLparameter(mdl, sa_param==0.0);    # initial driver steering command
    veh_params=[ux_param,sa_param];

    # obstacles
    Q = size(c.o.A)[1]; # number of obstacles TODO update these based off of LiDAR data
    @NLparameter(mdl, a[i=1:Q] == c.o.A[i]);
    @NLparameter(mdl, b[i=1:Q] == c.o.B[i]);
    @NLparameter(mdl, X_0[i=1:Q] == c.o.X0[i]);
    @NLparameter(mdl, Y_0[i=1:Q] == c.o.Y0[i]);
    obs_params=[a,b,X_0,Y_0];

    # define ocp
    s=Settings(;save=false,MPC=true);
    n,r=OCPdef(mdl,n,s,[pa,ux_param]);  # need pa out of params -> also need speed for c.m.model==:ThreeDOFv1

    # define objective function
    # follow the path -> min((X_path(Yt)-Xt)^2)
    if c.t.func==:poly
      path_obj=@NLexpression(mdl,sum(  (  (c.t.a[1] + c.t.a[2]*r.x[(i+1),2] + c.t.a[3]*r.x[(i+1),2]^2 + c.t.a[4]*r.x[(i+1),2]^3 + c.t.a[5]*r.x[(i+1),2]^4) - r.x[(i+1),1]  )^2 for i in 1:n.numStatePoints-1)  );
    elseif c.t.func==:fourier
      path_obj=@NLexpression(mdl,sum(  (  (c.t.a[1]*sin(c.t.b[1]*r.x[(i+1),1]+c.t.c[1]) + c.t.a[2]*sin(c.t.b[2]*r.x[(i+1),1]+c.t.c[2]) + c.t.a[3]*sin(c.t.b[3]*r.x[(i+1),1]+c.t.c[3]) + c.t.a[4]*sin(c.t.b[4]*r.x[(i+1),1]+c.t.c[4]) + c.t.a[5]*sin(c.t.b[5]*r.x[(i+1),1]+c.t.c[5]) + c.t.a[6]*sin(c.t.b[6]*r.x[(i+1),1]+c.t.c[6]) + c.t.a[7]*sin(c.t.b[7]*r.x[(i+1),1]+c.t.c[7]) + c.t.a[8]*sin(c.t.b[8]*r.x[(i+1),1]+c.t.c[8])+c.t.y0) - r.x[(i+1),2]  )^2 for i in 1:n.numStatePoints-1)  );
    end

    if c.m.model==:ThreeDOFv1
      # follow driver
      driver_obj=integrate(mdl,n,r.u[:,1];D=sa_param,(:variable=>:control),(:integrand=>:squared),(:integrandAlgebra=>:subtract));
      @NLobjective(mdl, Min, path_obj + driver_obj)
    elseif c.m.model==:ThreeDOFv2
      # follow driver
      #driver_obj=integrate(mdl,n,r.x[:,6];D=sa_param,(:variable=>:control),(:integrand=>:squared),(:integrandAlgebra=>:subtract));
      # minimum steering rate
      sr_obj=integrate(mdl,n,r.u[:,1];C=c.w.sr,(:variable=>:control),(:integrand=>:squared));
      #@NLobjective(mdl, Min, path_obj + sr_obj);
      @NLobjective(mdl, Min, sr_obj);
    else
      error("\n set c.m.model \n")
    end

    # obstacle postion after the intial postion
    @NLexpression(mdl, X_obs[j=1:Q,i=1:n.numStatePoints], X_0[j])
    @NLexpression(mdl, Y_obs[j=1:Q,i=1:n.numStatePoints], Y_0[j])

    # constraint position
    obs_con=@NLconstraint(mdl, [j=1:Q,i=1:n.numStatePoints-1], 1 <= ((r.x[(i+1),1]-X_obs[j,i])^2)/((a[j]+c.m.sm)^2) + ((r.x[(i+1),2]-Y_obs[j,i])^2)/((b[j]+c.m.sm)^2));
    newConstraint(r,obs_con,:obs_con);

    # LiDAR connstraint  TODO finish fixing the lidara constraints here
    @NLparameter(mdl, X0_params[j=1:2]==n.X0[j]);

  #  LiDAR_con=@NLconstraint(mdl, [i=1:n.numStatePoints-1], ((r.x[(i+1),1]-X0_params[1])^2+(r.x[(i+1),2]-X0_params[2])^2) <= (c.m.Lr + c.m.L_rd)^2); # not constraining the first state
  #  newConstraint(r,LiDAR_con,:LiDAR_con);
          #   1-3      4

    # constraint on progress on track (no turning around!)
    if c.t.dir==:posY
      progress_con=@NLconstraint(mdl, [i=1:n.numStatePoints-1], r.x[i,2] <= r.x[(i+1),2]);
      newConstraint(r,progress_con,:progress_con);
    elseif c.t.dir==:posX
      progress_con=@NLconstraint(mdl, [i=1:n.numStatePoints-1], r.x[i,1] <= r.x[(i+1),1]);
      newConstraint(r,progress_con,:progress_con);
    end

    # intial optimization
    optimize(mdl,n,r,s);

          #  1      2          3         4
    params=[pa,veh_params, obs_params,X0_params];

    return mdl,n,r,params
end
"""

--------------------------------------------------------------------------------------\n
Author: Huckleberry Febbo, Graduate Student, University of Michigan
Date Create: 4/6/2017, Last Modified: 4/7/2017 \n
--------------------------------------------------------------------------------------\n
"""

function getPlantData(n,params,e)
  MsgString = recv(e.s1);
  MsgIn = zeros(19);
  allidx = find(MsgString->MsgString == 0x20,MsgString);
  allidx = [0;allidx];
  for i in 1:19  #length(allidx)-1
    MsgIn[i] = parse(Float64,String(copy(MsgString[allidx[i]+1:allidx[i+1]-1])));
  end
  e.SA = MsgIn[1];                # Vehicle steering angle
  e.UX = MsgIn[2];                # Longitudinal speed
  e.X0=zeros(n.numStates);
  e.X0[1:5] = MsgIn[3:7];              # global X, global y, lateral speed v, yaw rate r, yaw angle psi
  e.X_0obs       = MsgIn[8:8+e.numObs-1];             # ObsX
  e.Y_0obs       = MsgIn[8+e.numObs:8+2*e.numObs-1];    # ObsY
  e.A            = MsgIn[8+2*e.numObs:8+3*e.numObs-1];  # ObsR
  e.B            = A;
  e.runJulia     = MsgIn[8+3*e.numObs+2];
end

"""

--------------------------------------------------------------------------------------\n
Author: Huckleberry Febbo, Graduate Student, University of Michigan
Date Create: 4/6/2017, Last Modified: 4/7/2017 \n
--------------------------------------------------------------------------------------\n
"""
function sendOptData(r,e)
  if r.dfs_opt[r.eval_num][:status][end]!==:Infeasible # if infeasible -> let user control TODO what is this YINgshi?
    MsgOut = [SA*ones(convert(Int64, floor(c.m.max_cpu_time/0.01))+1 );r.dfs_opt[r.eval_num][:t_solve][end];3;0]
  else
    MsgOut = [e.sa_sample;r.dfs_opt[r.eval_num][:t_solve][end];2;0];
  end

  # send UDP packets to client side
  MsgOut = [MsgOut;Float64(r.eval_num)];
  MsgOutString = ' ';
  for j in 1:length(MsgOut)
      MsgOutString = string(MsgOutString,' ',MsgOut[j]);
  end
  MsgOutString = string(MsgOutString," \n");
  send(e.s2,ip"141.212.141.245",36881,MsgOutString);  # change this to the ip where you are running Simulink!
end
"""

--------------------------------------------------------------------------------------\n
Author: Huckleberry Febbo, Graduate Student, University of Michigan
Date Create: 1/27/2017, Last Modified: 4/7/2017 \n
--------------------------------------------------------------------------------------\n
"""
function sharedControl(mdl,n,r,s,params,e)

  # update obstacle feild
  for i in 1:length(e.A)
    setvalue(params[3][1][i],e.A[i]);
    setvalue(params[3][2][i],e.B[i]);
    setvalue(params[3][3][i],e.X_0obs[i]);
    setvalue(params[3][4][i],e.Y_0obs[i]);
  end

  # rerun optimization
  status=autonomousControl(mdl,n,r,s,params);

  # sample solution
  sp_SA=Linear_Spline(r.t_ctr,r.X[:,6][1:end-1]);
  t_sample = Vector(0:0.01:n.mpc.tex);
  e.sa_sample=sp_SA[t_sample];

  # update status for Matlab
  if status!=:Infeasible; e.status=1.; else e.status=0.; end

end

"""
evalNum()
# to extract data from a particular iteration number
# will not work unless the data was saved; i.e., s.save = true
--------------------------------------------------------------------------------------\n
Author: Huckleberry Febbo, Graduate Student, University of Michigan
Date Create: 2/21/2017, Last Modified: 2/21/2017 \n
--------------------------------------------------------------------------------------\n
"""
function evalNum(Idx)
  eval_num=0;
  for i in 1:length(r.dfs_opt)
    if r.dfs_opt[i][:iter_num][1]==Idx
      eval_num=i;
      break
    end
  end
  print(eval_num);
  s=Settings(;format=:png,MPC=false);
  cd("results/test1"); allPlots(n,r,s,eval_num); cd(main_dir)
end



end # module