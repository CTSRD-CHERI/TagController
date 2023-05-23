# Graphs 
import matplotlib.pyplot as plt 
import numpy as np

# Colour for each type
# Original
# incremental
# pipelined
# pipelined and OOO


## Read and write throughput
## table of miss rates
# experiment     | root miss interval  |  leaf miss interval
#--------------------------------------------
# every leaf     |   512*128           |  512 
# every root     |  512                |  4
# every leaf line|  128                |  1
# every root line|  1                  |  1

## ROOT ONLY
fig, ax = plt.subplots(figsize=(10,7))
width = 0.1
multiplier = 0

designs = ["Original", "Improved state machine", "Pipelined", "Pipelined and OOO"]
colours=["tab:blue","tab:orange","tab:green","tab:red"]
hatchs = ["/", "|", "x", "."]
n = np.arange(len(designs))

experiments = []

def plot_bunch(tpts):
    global multiplier
    offset = width*multiplier
    xs = offset + n*width
    for x,(tpt,(lab,(col,h))) in zip(xs, zip(tpts, zip(designs,zip(colours,hatchs)))):
        rect = ax.bar(x, tpt,width,label=lab, color=col, hatch=h)
        # ax.bar_label(rect)
    print(offset + n*width)
    multiplier += 5

# read every tag 
# offset = width*multiplier
# experiments += ["read every leaf tag"]
# tpts = [0.3333,0.9998,0.9998,0.9998]
# xs = offset + n*width
# for x,(tpt,(lab,col)) in zip(xs, zip(tpts, zip(designs,colours))):
#     rect = ax.bar(x, tpt,width,label=lab, color=col)
#     # ax.bar_label(rect)
# print(offset + n*width)
# multiplier += 5

experiments += ["(read) 1 leaf tag"]
tpts = [0.3333,0.9998,0.9998,0.9998]
plot_bunch(tpts)
ax.legend()

# write every tag 

experiments += ["(write) 1 leaf tag"]
tpts = [0.3332,0.9986,0.9995,0.9993]
plot_bunch(tpts)

# read every root

experiments += ["(read) 1 root tag"]
tpts = [0.3312,0.9715,0.9679,0.9642]
plot_bunch(tpts)

# write every root
experiments += ["(write) 1 root tag"]
tpts = [0.3312,0.9718,0.9682,0.9647]
plot_bunch(tpts)

# read every leaf line
experiments += ["(read) 512 leaf tags"]
tpts = [0.3251,0.9008,0.8896,0.8786]
plot_bunch(tpts)
 
# write every leaf line
experiments += ["(write 512 leaf tags"]
tpts = [0.3247,0.8992,0.8896,0.8771]
plot_bunch(tpts)

# read every root line

experiments += ["(read) 512 root tags"]
tpts = [0.0769,0.0769,0.0556,0.1178]
plot_bunch(tpts)

# write every leaf line
experiments += ["(write) 512 root tags"]
tpts = [0.0769,0.0782,0.0564,0.1194]
plot_bunch(tpts)


ax.set_ylabel("Requests completed per cycle)")
ax.set_title("Throughput for root-only requests")
ax.set_xticks(np.arange(len(experiments))*5*width + 1.5*width, experiments)
plt.savefig(f"Logs/figures/bar_sequential_roots.png")


## ROOT AND LEAF
# read every tag 
# write every tag 
# read every root
# write every root
# read every leaf line
# write every leaf line
# read every root line
# write every leaf line


