import math
# minimize f(x) = 0.5*(x0^2 + kappa*x1^2); condition number = kappa; min at 0.
def iters(kappa, method, eps=1e-8, maxit=5_000_000):
    x=[1.0,1.0]; L,mu=kappa,1.0
    def fval(x): return 0.5*(x[0]*x[0]+kappa*x[1]*x[1])
    if method=="gd":
        s=2.0/(L+mu)
        for k in range(1,maxit):
            g=[x[0],kappa*x[1]]; x=[x[0]-s*g[0],x[1]-s*g[1]]
            if fval(x)<eps: return k
    elif method=="momentum":   # Polyak heavy-ball, optimal params -> sqrt(kappa)
        b=((math.sqrt(L)-math.sqrt(mu))/(math.sqrt(L)+math.sqrt(mu)))**2
        a=4.0/((math.sqrt(L)+math.sqrt(mu))**2); xp=x[:]
        for k in range(1,maxit):
            g=[x[0],kappa*x[1]]; xn=[x[i]-a*g[i]+b*(x[i]-xp[i]) for i in range(2)]
            xp,x=x,xn
            if fval(x)<eps: return k
    elif method=="newton":     # x <- x - H^{-1} grad ; H=diag(1,kappa)
        for k in range(1,maxit):
            g=[x[0],kappa*x[1]]; x=[x[0]-g[0], x[1]-g[1]/kappa]
            if fval(x)<eps: return k
    return maxit
print(f"{'kappa':>7} {'GD (~k)':>10} {'momentum(~sqrt k)':>18} {'Newton(~1)':>11}")
for kappa in (10,100,1000,10000):
    print(f"{kappa:7d} {iters(kappa,'gd'):10d} {iters(kappa,'momentum'):18d} {iters(kappa,'newton'):11d}")
