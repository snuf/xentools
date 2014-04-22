gxentop
=======
Push VM statistics, cpu, disk and net from xentop to carbon either direct
or by means of collectd, supports xapi and xm.

Examples in the .png:
---------
* To net TX/RX: this is a routerVM controlled by cloudstack, and doing moderate network load. 
* Top Read IO shows us the most misbehaving VM in our cloud; it seems that the VM from account id 9 with vm_instance id 1452 is the most misbehaving VM which is hammering the shared storage underneath, and it is doing this via a disk known to Xen with id 5632.

This Xen ID can be used to get the specific disk ID with the xenstore-ls and xl commands:

```
    # xenstore-ls `xl block-list i-9-1452-VM | awk '{ print $7 }' | grep 5632`
    frontend = "/local/domain/386/device/vbd/5632"
    online = "1"
    sm-data = ""
     storage-type = "nfs"
     scsi = ""
      0x12 = ""
       0x83 = "AIMAMQIBAC1YRU5TUkMgIDJkNjZhYTVmLTNmNmMtNDQ0Zi04MzI3LTJjOWU1NGVjMmIxNyA="
       0x80 = "AIAAEjJkNjZhYTVmLTNmNmMtNDQgIA=="
     vdi-uuid = "2d66aa5f-3f6c-444f-8327-2c9e54ec2b17"
     mem-pool = "a119270f-6fac-7b22-84a5-44816ff20dc6"
    params = "/dev/sm/backend/a119270f-6fac-7b22-84a5-44816ff20dc6/2d66aa5f-3f6c-444f-8327-2c9e54ec2b17"
    state = "4"
    dev = "hdc"
    physical-device = "fd:c"
    removable = "1"
    mode = "w"
    frontend-id = "386"
    type = "phy"
    max-ring-page-order = "0"
    hotplug-status = "connected"
    feature-barrier = "1"
    sectors = "524288000"
    info = "0"
    sector-size = "512"
    kthread-pid = "32742"
    [root@mccpvm24 ~]# 
```

