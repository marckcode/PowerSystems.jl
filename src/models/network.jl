export Branch
export Line
export Transformer2W
export Transformer3W
export Network

abstract type 
    Branch
end

struct Line <: Branch
    number::Int
    status::Bool
    connectionpoints::Tuple{Bus,Bus}
    r::Float64 #[pu]
    x::Float64 #[pu]Co
    b::Float64 #[pu]
    rate::Float64  #[MVA]
end

"""
The 2-W transformer model uses an equivalent circuit assuming the impedance is on the High Voltage Side of the transformer. 
The model allocates the iron losses and magnetezing suceptance to the primary side 
"""

struct Transformer2W <: Branch
    number::Int
    status::Bool
    connectionpoints::Tuple{Bus,Bus}    
    r::Float64 #[pu]
    x::Float64 #[pu]
    zb::Float64 #[pu]
    tap::Float64 # [0 - 2]
    α::Float64 # [radians]
    rate::Float64  #[MVA]
end

struct Transformer3W <: Branch
    number::Int
    status::Bool
    connectionpoints::Tuple{Bus,Bus,Bus}    
    r::Tuple{Float64,Float64,Float64} #[pu]
    x::Tuple{Float64,Float64,Float64} #[pu]
    zb::Tuple{Float64,Float64,Float64} #[pu]
    tap::Tuple{Float64,Float64,Float64}  # [0 - 2]
    α::Tuple{Float64,Float64,Float64}  # [radians]
    rate::Tuple{Float64,Float64,Float64}  #[MVA]
end

function build_ybus(sys::SystemParam, branches::Array{T}) where {T<:Branch}

    Ybus = spzeros(Complex{Float64},sys.busquantity,sys.busquantity)
    max_flows = Array{Float64}(length(branches))
    
    for b in branches

        if typeof(b) == PowerSchema.Line

            Y11 = (1/(b.r + b.x*1im) + (1im*b.b)/2)*b.status;
            Ybus[b.connectionpoints[1].number,
                b.connectionpoints[1].number] += Y11;
            Y12 = (-1./(b.r + b.x*1im))*b.status;
            Ybus[b.connectionpoints[1].number, 
                b.connectionpoints[2].number] += Y12;
            #Y21 = Y12
            Ybus[b.connectionpoints[2].number, 
                b.connectionpoints[1].number] += Y12;
            #Y22 = Y11;
            Ybus[b.connectionpoints[2].number,
                b.connectionpoints[2].number] += Y11;    

            max_flows[b.number] = b.rate
        
        end

        if typeof(b) == PowerSchema.Transformer2W 

            y = 1/(b.r + b.x*1im)
            y_a = y/(b.tap*exp(b.α*1im))
            c = 1/b.tap

            Y11 = (y_a + y*c*(c-1) + (b.zb))*b.status;
            Ybus[b.connectionpoints[1].number,
                b.connectionpoints[1].number] += Y11;
            Y12 = (-y_a) * b.status;
            Ybus[b.connectionpoints[1].number, 
                b.connectionpoints[2].number] += Y12;
            #Y21 = Y12
            Ybus[b.connectionpoints[2].number, 
                b.connectionpoints[1].number] += Y12;
            Y22 = (y_a + y*(1-c)) * b.status;;
            Ybus[b.connectionpoints[2].number,
                b.connectionpoints[2].number] += Y22;    

            max_flows[b.number] = b.rate                

        end

        if typeof(b) == PowerSchema.Transformer3W 

            warn("Data contains a 3W transformer")

            Y11 = (1/(b.r + b.x*1im) + (1im*b.b)/2)*b.status;
            Ybus[b.connectionpoints[1].number,
                b.connectionpoints[1].number] += Y11;
            Y12 = (-1./(b.r + b.x*1im))*b.status;
            Ybus[b.connectionpoints[1].number, 
                b.connectionpoints[2].number] += Y12;
            #Y21 = Y12
            Ybus[b.connectionpoints[2].number, 
                b.connectionpoints[1].number] += Y12;
            #Y22 = Y11;
            Ybus[b.connectionpoints[2].number,
                b.connectionpoints[2].number] += Y11;    

            max_flows[b.number] = b.rate                

        end

    end

    return Ybus, max_flows

end 

function build_ptdf(sys::SystemParam, branches::Array{T}, nodes::Array{Bus}) where {T<:Branch}

    n_b = length(branches)
    
    n_n = sys.busquantity;

    A = spzeros(Float64,n_n,n_b);
    B = zeros(n_n,n_n);
    X = zeros(n_b,n_b);

   #build incidence matrix 
   #incidence_matrix = A

    for b in branches

        A[b.connectionpoints[1].number, b.number] =  1;

        A[b.connectionpoints[2].number, b.number] = -1;

        X[b.number,b.number] = b.x;

        Y11 = (1/b.x)*b.status;
        B[b.connectionpoints[1].number,
            b.connectionpoints[1].number] += Y11;
        Y12 = -1*Y11;
        B[b.connectionpoints[1].number, 
            b.connectionpoints[2].number] += Y12;
        #Y21 = Y1
        B[b.connectionpoints[2].number, 
            b.connectionpoints[1].number] += Y12;
        #Y22 = Y11;
        B[b.connectionpoints[2].number,
            b.connectionpoints[2].number] += Y11;

    end

    slack_position = -9; 

    for n in nodes
        if get(n.bustype) == "SF"
            slack_position = n.number
        end
    end

    if slack_position != -9 
        B = B[setdiff(1:end, slack_position), setdiff(1:end, slack_position)]

        A = A[setdiff(1:end, slack_position), :]
    
        S = inv(X)*A'*inv(B);
        
        S = hcat(S[:,1:slack_position-1],zeros(n_b,),S[:,slack_position:end-1])

    elseif slack_position == -9 
        
        warn("Slack bus not identified in the Bus/Nodes list, can't build PTLDF")
        S = Nullable{Array{Float64}}()
    end

    return S, A

end

struct Network 
    linequantity::Int
    ybus::SparseMatrixCSC{Complex{Float64},Int64}
    ptdlf::Nullable{Array{Float64}}
    incidence::Nullable{Array{Int}}
    maxflows::Array{Float64} 

    function Network(sys::SystemParam, branches::Array{T}, nodes::Array{Bus}) where {T<:Branch}
        
        for n in nodes
            if isnull(n.bustype) 
                error("Bus/Nodes data does not contain information to build an AC network")
            end
        end
        
        ybus, maxflow = build_ybus(sys,branches);
        ptdlf, A = build_ptdf(sys, branches, nodes)    
        new(length(branches),
            ybus, 
            Nullable{Array{Float64}}(),
            Nullable{Array{Int}}(),
            maxflow)
    end

end
