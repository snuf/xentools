gxentop
=======
Push VM statistics, cpu, disk and net from xentop to carbon either direct
or by means of collectd, supports xapi and xm.

2 Examples in the gxentop.pl-exampleGraphiteDashboard.png are nice:
•	To net TX/RX: this is a routerVM controlled by cloudstack, and doing moderate network load. 
•	Top Read IO shwwwows us the most misbehaving VM in  our cloud; it seems that the VM from tenant 325 with VM ID 17219 is the most misbehaving VM which is hammering the shared storage underneath, and it is doing this via a disk known to cloudstack with id 51712.
