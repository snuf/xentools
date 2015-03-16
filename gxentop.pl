#!/usr/bin/perl -w
# Licensed to the Apache Software Foundation (ASF) under one
# or more contributor license agreements.  See the NOTICE file
# distributed with this work for additional information
# regarding copyright ownership.  The ASF licenses this file
# to you under the Apache License, Version 2.0 (the
# "License"); you may not use this file except in compliance
# with the License.  You may obtain a copy of the License at
#
#   http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing,
# software distributed under the License is distributed on an
# "AS IS" BASIS, WITHOUT WARRANTIES OR CONDITIONS OF ANY
# KIND, either express or implied.  See the License for the
# specific language governing permissions and limitations
# under the License.
#
############################################################
# Parser for xentop to graphite (xentop -d 10 -b -x -n -v), 
# by either a direct connection or in collectd input format 
# so it can be used with exec from collectd
# 
# Note:
# Sometimes bits fall over due to wrapping of int in xen code
# "work around" that. an example: 18446744073562487816, 
#
use strict;
use Getopt::Std;
use IO::Socket::INET;
local $ENV{PATH} = "$ENV{PATH}:/sbin:/usr/sbin";
$| = 1;
my $DEBUG = $ENV{DEBUG};

# connect
sub conGraphite {
    my $target = shift || "localhost";
    my $port = shift || 2003;
    my $sock = new IO::Socket::INET (
        PeerAddr => $target,
        PeerPort => $port,
        Proto => 'tcp',
    );
    if (!$sock) {
        warn "Could not create socket: $!\n" unless $sock;
        return undef;
    }
    return $sock;
}

# number of running VMs according to xe
sub vmCount {
    my $vm_count=0;
    if (-e "/etc/init.d/xend") {
        chomp($vm_count=`xm list | grep -v ^Name | wc -l`);
    } else {
        chomp(my $hostname=`hostname`);
        chomp(my $host_uuid=`xe host-list |grep $hostname -B1 |grep uuid |awk -F': ' '{print \$2}'`);
        chomp($vm_count=`xe vm-list resident-on=$host_uuid power-state=running params=uuid | grep -v ^\$ | wc -l`);
    }
    return $vm_count;
}

# because xentop only returns 10 chars for the name
sub getRealnames {
    my $fl = shift || 10;
    open(RL, "xl list|") ||
        die "Unable to fetch real list: $!";
    my $nash;
    while(<RL>) {
        if ($_ !~ /^(Name|Domain-0) \s+ /x) {
            my ($hn, $id, undef) = split(/\s+/, $_);
            my $short = sprintf("%.".$fl."s", $hn);

            $nash->{ $hn }->{ id } = $id;
            $nash->{ $hn }->{ name } = $hn;
            $nash->{ $hn }->{ short } = $short;
            if (!defined($nash->{ $nash->{ $hn }->{ short } })) {
                $nash->{ $nash->{ $hn }->{ short } } = $nash->{ $hn };
            } elsif (length($hn) <= $fl) {
                # print "$hn shorter or equal $fl\n";
            } else {
                my $chn = $nash->{ $hn }->{ short };
                print STDERR "possible collision for $hn with $chn\n";
            }
        }
    }
    close(RL);
    return $nash;
}

# delta value in hash with previous absolute value
# * include int oddity "correction", does mean we miss some bits
# * proc makes up some characters allong the way.. 
# * originates from /proc/net/dev being broken since 1999...
# * should be fixed in 2.6.35..
#
# example where a number "jumps" and "jumps" back again:
# r-2044-VM: NETTX_k -> 2283403
# delta: 10, val: 2283403, abs: 2283393, pabs: 2283388, line: 204
# r-2044-VM: NETTX_k -> 3349332
# delta: 1065929, val: 3349332, abs: 2283403, pabs: 2283393, line: 204
# r-2044-VM: NETTX_k -> 2283425
# 1366796140:underrun (0) 22 ( 2283403 replaced 3349332 ) set -1065907 to 22, line: 204
# delta: 22, val: 2283425, abs: 3349332, pabs: 2283403, line: 204
# r-2044-VM: NETTX_k -> 2283429
# delta: 4, val: 2283429, abs: 2283425, pabs: 3349332, line: 204
#
sub Delta {
    my $val = shift || return 0;
    my $hash = shift || return 0;
    my $quirky_mode = shift || 0;

    my $abs = $hash->{ abs };
    my $pabs = $hash->{ pabs };
    my ($package, $filename, $line) = caller;
    my $delta = $abs ? $val - $abs : 0;

    # if xentop/proc tries to cheat us
    if ($quirky_mode != 0) {
        # check if we have absolute and absolute is larger than 0
        if (defined($abs) && $abs > 0) {
            # and abs is 5 times $val, there are not just appended digits, 
            # or delta larger than is 1/4th of abs
            if ($val > (5 * $abs) || $val =~ /^$abs(\d{1,2})/ || $delta > ($abs / 4)) {
                my $seen = $hash->{ quirks }++;
                # maybe 2 as we might have to consecutive quirks ?
                if ($seen >= 1) {
                    $hash->{ quirks } = 0;
                    print STDERR time().":quirk reset ($seen) d:$delta, v:$val, a:$abs, p:$pabs, l:$line\n";
                } else {
                    my $oval = $val;
                    $val = $abs;
                    print STDERR time().":quirk cheat ($seen) d:$delta, v:$val (was $oval), a:$abs, p:$pabs, l:$line\n";
                }
                $hash->{ pabs } = $abs;
                $hash->{ abs } = $val;
                $delta = $abs ? $val - $abs : 0;
                print STDERR time().":quirk return ($seen) d:$delta, a:$val, p:$pabs, l:$line\n";
                return $delta;
            }
        } else {
            $hash->{ quirks } = 0;
        }
    }

    # if delta smaller than 0 means wrap or other proc oddity where garble gets introduced at the front
    if ($delta < 0) {
        my $seen = $hash->{ ndelta }++;
        # should not occur
        if ($seen >= 1) {
            $hash->{ pabs } = $val;
            $hash->{ abs } = $val;
            print STDERR time().":underrun reset ($seen) d:0, a:$val (was $abs), p:$val (was $pabs), l:$line\n";
            return 0;
        # normal underrun situation
        } else {
            my $od = $delta;
            if (defined($pabs) && $pabs > 0) {
                print STDERR time().":underrun pabs o:$od, d:0, v:$val, a:$pabs (was $abs), p:$pabs, l:$line\n";
                $delta = $val - $pabs;
                $abs = $hash->{ abs } = $pabs;
            } else {
                print STDERR time().":underrun nopabs o:$od, d:0, v:$val, a:$abs, l:$line\n";
                $abs = $hash->{ abs } = $val;
            }
            print STDERR time().":underrun ($seen) o:$od, d:0, v:$val, a:$pabs (was $abs), p:$pabs, l:$line\n";
            return 0;
        }

    # this one is for the VBDs, seems to be a bug that's hit so now and then llu...
    # * don't delta anything reset all counters to this.
    } elsif ($delta > 18446744000000000000) {
        $hash->{ pabs } = $val;
        $hash->{ abs } = $val;
        print STDERR time().":overflow: $val - $abs = $delta (now 0), line: $line\n";
        return 0;
    # normale operation, reset underrrun
    } else {
        my $delta = $abs ? $val - $abs : 0;
        $hash->{ pabs } = $abs;
        $hash->{ abs } = $val;
        $hash->{ quirks } = 0;
        $hash->{ ndelta } = 0;
        return $delta;
    }
    return 0;
}

# crunch and mangle a string into the hash
sub crush {
    my $string = shift;
    my $hash = shift;
    $string =~ s/(\d+)(\w+)/$2 $1/g;
    my @arr = split(/\s+/, $string);
    return \@arr;
}

# put out to socket 
sub pOut {
    my $msg = shift;
    my $con = shift || undef;
    if ($con) {
        print $con "$msg\n";
    } elsif ($msg =~ /(.*)\.(.*) \s+ ([\d\.]+) \s+ (\d+)/xi) {
        my $p = $1;
        my $t = $2;
        my $v = $3;
        my $time = $4;
        print "$p/gauge-$t $time:$v\n";
    } else {
        print "dude!";
    }
}

sub usage {
    print "-t (graphite_host) host for direct graphite connection\n";
    print "-p (port number) port for direct graphite connection\n";
    print "-c collectd instead of graphite, prints to stdout\n";
    print "-d (number) interval for metrics\n";
    print "-D (number) Debug level\n";
    print "-P (dot.seperated.prepend.for.graphite)\n";
    print "-e (whatever) env append, deduced from dom0 name by default\n";
    print "$0: ((-t graphite_host) (-p port|2003)|-c) (-d delay|10)\n";
    exit 1;
}

####
# Main
####
my (%opts);
getopts('cp:t:d:e:P:D:h', \%opts);
usage if ($opts{h} || !%opts);
my $collectd = $opts{c} || undef;
my $delay = $opts{d} || 10;
my $target = $opts{t} || "10.200.10.23";
my $port = $opts{p} || 2003;
my $prep = $opts{P} || undef; 
my $env = $opts{e} || undef;
if (!defined($DEBUG)) {
    $DEBUG = $opts{D} || 0;
}

# pre-define the top headers, command and prepend for graphite
my $run = "xentop -d $delay -x -n -v -b";
my @tm = qw(NAME STATE CPU_s CPU_pct MEM_k MEM_pct MAXMEM_k MAXMEM_pct VCPUS NETS NETTX_k NETRX_k VBDS VBD_OO VBD_RD VBD_WR VBD_RSECT VBD_WSECT SSID);
chomp (my $dom0 = `hostname`);
$prep = "vms.xenserver" if (!$prep);
# distinguish between beta/prod xenserver
if (!$env) {
    $env=$dom0;
    $env=~s/[-\d+]+//;
}
$prep .= ".$env";


####
my $data;
# set a global host...
my $host;
my $timer;
my $names;
my $graphite = undef;
# if debug don't send to graphite
if ($DEBUG) {
    print "debugging: $DEBUG\n";
} else {
    if (!$collectd) {
        close(STDIN);
        close(STDERR);
        close(STDOUT);
    }
}

# when Xenserver starts it's not in the pool yet, getting in the pool
# screws up the NIC config, which screws up connecting in the first place
# and leaves us hanging. So wait till a VM is spun up, as we know everything
# works out then. (another VM besides dom0)
my $vmcount = vmCount();
while($vmcount < 1) {
    print "Waiting for VMs to get assigned: $vmcount\n" if ($DEBUG);
    select(undef,undef,undef, $delay);
    $vmcount = vmCount();
}

# go into a loop
open(RUN, "$run|") || die "unable to run: $run";
while(<RUN>) {
    chomp (my $line = $_);
    # get the real names everytime the first line comes by... 
    if ($line =~ /^ (\s+)? (NAME)/xi) {
        # eval not to go flat on our face
        if (!$collectd) {
            print STDERR "reconnecting\n" if ($DEBUG);
            eval {
                local $SIG{'ALRM'} = sub { die "zork" };
                alarm(5);
                $graphite = undef;
                $graphite = conGraphite($target, $port);
                alarm(0);
            };
        }
        $names = getRealnames(10);
    # i-413-2523 --b--- 124076 1.1 4194256 1.6 4195328 1.6 2 1 
    # 1357455 1050656 3 180 940255 1146319 619510933 129211372 0
    } elsif ($line =~ /^ (\s+)? (([\w\-\d]+) \s+ ([\w\-]+) \s+
            (.*))/ix && $line !~ /^ (\s+)? (NAME|VBD|Net|VCPU)/xi) {
        my @top = split(/\s+/, $2);
        $timer = time();
        $host = $top[0];
        if ($3 =~ /Domain-0/) {
            $host = $dom0;
        # contains the short and the long, so if they ever fix it...
        } elsif (defined($names->{ $3 })) {
            $host = $names->{ $3 }->{ name };
        } else {
            print STDERR "that's strange, a host we don't know: $3";
            die;
        }
        print STDERR "host: $host\n" if ($DEBUG > 1);
        # Traverse through the header bits and get the data
        #  NAME STATE CPU_s CPU_pct MEM_k MEM_pct MAXMEM_k MAXMEM_pct
        #  VCPUS NETS NETTX_k NETRX_k VBDS VBD_OO VBD_RD VBD_WR VBD_RSECT
        #  VBD_WSECT SSID NAME STATE CPU(sec) CPU(%) MEM(k) MEM(%)
        #  MAXMEM(k) MAXMEM(%) VCPUS NETS NETTX(k) NETRX(k) VBDS
        #  VBD_OO VBD_RD VBD_WR VBD_RSECT VBD_WSECT SSID
        foreach my $t (@tm) {
            my $q = 0;
            if ($t !~ /(STATE|NAME)/) {
                my $val = shift @top;
                my $delta;
                # what can we and can't we delta?
                if (lc($t) !~ /(mem|_pct$|vcpus|nets|vbds|ssid)/) {
                    if ($DEBUG > 2) {
                        print STDERR "$host: $t -> $val\n";
                    }
                    $q = 1 if ($t =~ /(NETTX_k|NETRX_k)/i);
                    $delta = Delta($val, 
                        \%{ $data->{ $host }->{ global }->{ lc($t) } }, 
                        $q);
                } else {
                    $delta = 
                        $data->{ $host }->{ global }->{ lc($t) } = 
                        $val;
                }
                pOut("$prep.$host.global.".lc($t)." $delta $timer", $graphite);
            } elsif ($t =~ /NAME/) {
                # skip the name
                shift @top;
            } elsif ($t =~ /STATE/) {
                my $tv = shift @top;
                # the later is the transition state..., first two 
                # running and blocked
                if ($tv =~ /([br])/ || $tv =~ /------/) {
                    my $state = "ok";
                    $data->{ $host }->{ global }->{ lc($t) }->{ $state } = 1;
                    pOut("$prep.$host.global.".lc($t).".$state 1 $timer", 
                        $graphite);
                } else {
                    my $state = "other";
                    $data->{ $host }->{ global }->{ lc($t) }->{ $state } = 1;
                    pOut("$prep.$host.global.".lc($t).".$state 1 $timer", 
                        $graphite);
                }
            } else {
                print STDERR "unknown data field $t\n" if ($DEBUG > 1);
            }
        }
    # VCPUs(sec): 0: 1194946s 1: 1421524s 2: 934699s 3: 882863s
    } elsif ($line =~ /^VCPUs\(sec\): \s+ (.*)/x) {
        my $mt = $1;
        $mt =~ s/(\:|s)//g;
        my @arr = split(/\s+/, $mt);
        while(@arr) {
            my $key = shift @arr;
            my $val = shift @arr;
            pOut("$prep.$host.cpu.$key ".
                Delta($val, \%{ $data->{ $host }->{ cpu }->{ $key } })." $timer", 
                $graphite);
        }
    # Net0 RX: 0bytes 0pkts 0err 0drop  TX: 1848bytes 44pkts 0err 336629drop
    } elsif ($line =~ /Net(\d+) \s+ RX: \s+ (.*) \s+ TX: \s+ (.*)/x) {
        my $rx = crush($2, \%{ $data->{ $host }->{ net }->{$1}->{ rx } });
        while(@{ $rx }) {
            my $key = shift @{ $rx };
            my $val = shift @{ $rx };
            pOut("$prep.$host.net.$1.rx.$key ".
                Delta($val, \%{ $data->{ $host }->{ net }->{ $1 }->{ rx }->{ $key } }, 1)." $timer",
                $graphite);
        }
        my $tx = crush($3, \%{ $data->{ $host }->{ net }->{$1}->{ tx } });
        while(@{ $tx }) {
            my $key = shift @{ $tx };
            my $val = shift @{ $tx };
            pOut("$prep.$host.net.$1.tx.$key ".
                Delta($val, \%{ $data->{ $host }->{ net }->{ $1 }->{ tx }->{ $key } }, 1)." $timer",
                $graphite);
        }
    # VBD BlkBack 51712 [ca: 0] OO: 8361 RD: 480088154 WR: 72622169 RSECT: 18446744073562662986 WSECT: 1384256298
    #        riiiiighhhhttt!!----------------------------------------------^^^^^^^^^^^^^^^^^^^^
    } elsif ($line  =~ /(VBD +\s BlkBack) \s+ (\d+) \s+ \[([\w\d:\s]+)\] \s+ (.*)/x) {
        my $mt = $4;
        my $id = $2;
        $mt =~ s/\://g;
        my @arr = split(/\s+/, $mt);
        # my $hash;
        while(@arr) {
            my $key = shift @arr;
            my $val = shift @arr;
            my $delta = Delta($val, \%{ $data->{ $host }->{ vbd }->{ $id }->{ lc($key) } });
            pOut("$prep.$host.vbd.$id.".lc($key)." $delta $timer", $graphite);
        }
    } else {
        print STDERR "Mismatch: $_\n";
    }
}
close(RUN);
