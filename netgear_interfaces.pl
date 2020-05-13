#!/usr/bin/perl -wT
# original by Dorijan Santini < 2018, config file support 2019
# extensive rewrite Matija Nalis <mnalis-perl@voyager.hr> 20181203+
# GPLv3+

use strict;
use autodie;

use Expect;
use Set::IntSpan;

my $NETGEAR_IP = '192.168.0.254';
my $NETGEAR_PORT = 60000;
my $NETGEAR_USER = 'admin';
my $NETGEAR_PASSWORD = 'FIX-YOUR-PASSWORD';
my $NETGEAR_ENPASSWORD = '';
my $NETGEAR_ADMINPROMPT = '\(Broadcom FASTPATH Switching\) #';
my $NETGEAR_VLANPROMPT = '\(Vlan\)#';
my $NETGEAR_CONFIGPROMPT = '\(Config\)#';

my $MAXPORT=24;
my $EXPECT_TIMEOUT = 10;

my %VLANS;
my %OLD_VLANS;
my @PORTS;
my $NUKEALL=$ENV{NUKEALL} || 1;				# set to 1 to force slow about 1min (but sure) nuke/recreate... if 0, delete only VLANs you must - this is MUCH faster (about 20sec) but BEWARE -- it never removes old VLANs, but just add new ones!
my $DRYRUN=$ENV{DRYRUN} || 0;
my $DEBUG=$ENV{DEBUG} || 0;
my @TODO_PORTS;
my $_expect;

%ENV = (PATH => '/usr/local/bin:/usr/bin');	# clean up environment and setup PATH

# FIXME - staviti help za parametre i da se zali ako neki fali
# DONE - da parsea config file umjesto ovog hardcoded
# FIXME - da snimi config kada je gotov? ili ne... da pita najbolje! (ili opcija za save)
# FIXME - scriptu  upload na github ili gitlab (dorijan neka si napravi account)
# FIXME - NUKEALL default 1 ? ili kao parametar configure-add configure-full
# FIXME - password/IP/PORT stavi u config file isto? ili barem ENV.

# send command now
sub exp_send_immediately($) {
    my ($cmd) = @_;

    if ($DRYRUN) { 
                print "DRYRUN EXP_SEND_IMMEDIATELY:\n";
                print "\tS: $cmd\n";
                return;
    }
    $_expect->send ("$cmd\r")
}

# expect prompt, and send reply
sub exp_wait_reply($$) {
    my ($wait, $response) = @_;

    if ($DRYRUN) { 
                print "DRYRUN EXP_WAIT_REPLY:\n";
                print "\tW: $wait\n";
                print "\tS: $response\n";
                return;
    }
    
    $_expect->expect ($EXPECT_TIMEOUT, [ $wait => sub {
        my $self = shift;
        $self->send("$response\r");
#        exp_continue; 
    }] );
}

# initial expect login
sub exp_login() {
    #$Expect::Exp_Internal = 3 if $DEBUG;
    #$Expect::Debug = 3 if $DEBUG;
    $Expect::Log_Stdout = 0 if ! $DEBUG;

    $_expect = Expect->new;
    
    my $command = "/usr/bin/telnet $NETGEAR_IP $NETGEAR_PORT";	# FIXME: should really use Net::Telnet and Expect->exp_init()
    $_expect->raw_pty(1);
    $_expect->spawn ($command)
        or die "Cannot spawn $command: $!\n";

    exp_wait_reply ('Applying Interface configuration, please wait ...',	$NETGEAR_USER);
    exp_wait_reply ('Password:',						$NETGEAR_PASSWORD);
    exp_wait_reply ('\(Broadcom FASTPATH Switching\) >',			'enable');
    exp_wait_reply ('Password:',						$NETGEAR_ENPASSWORD);
    exp_wait_reply ($NETGEAR_ADMINPROMPT,					'terminal length 47');
}

# add new VLAN (must be in "vlan database" mode first)
sub exp_vlan_add ($) {
    my ($vlan) = @_;
    exp_wait_reply ($NETGEAR_VLANPROMPT,		"vlan $vlan");
    exp_wait_reply ($NETGEAR_VLANPROMPT, 		"vlan makestatic $vlan");
    exp_wait_reply ($NETGEAR_VLANPROMPT, 		"vlan name $vlan vlan_$vlan");
}

# del existing VLAN (must be in "vlan database" mode first)
sub exp_vlan_del ($) {
    my ($vlan) = @_;
    exp_wait_reply ($NETGEAR_VLANPROMPT,		"no vlan $vlan");
}

# modify port VLAN membership
sub exp_port_mod ($$$) {
    my ($action, $vlan, $port) = @_;
    my $blackhole = 666;
    my $NETGEAR_INTERFACEPROMPT = "(Interface 0/$port)";
    
    exp_wait_reply ($NETGEAR_CONFIGPROMPT,		"interface 0/$port");
    
    if ($action eq 'exclude') {
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan participation auto $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"no vlan tagging $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan pvid $blackhole");
    } elsif ($action eq 'untagged') {
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan participation include $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"no vlan tagging $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan pvid $vlan");
    } elsif ($action eq 'tagged') {
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan participation include $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan tagging $vlan");
        exp_wait_reply ($NETGEAR_INTERFACEPROMPT,	"vlan pvid $blackhole");
    } else {
        die "exp_port_mod: invalid action: $action vlan=$vlan port=$port";
    }
    exp_wait_reply ($NETGEAR_INTERFACEPROMPT,		'exit');
}


# parsea listu VLANova i postavlja $VLANS{$vlan} za svaki postojeci VLAN
sub setup_VLANS() {
    exp_wait_reply ($NETGEAR_ADMINPROMPT,		'show vlan brief');

    if ($DRYRUN) { 
                print "DRYRUN setup_VLANS exit\n";
                return;
    }
        
    $_expect->expect ($EXPECT_TIMEOUT,
        #vlan.1037      | 1037  | vlan
        #vlan.1038      | 1038  | vlan
        #vlan.1039      | 1039  | vlan
        [ '^(\d+)\s+\w+' =>	sub {	my $self = shift;
                                        $VLANS{($self->exp_matchlist())[0]} = -1;	# indicate VLAN found (which should be deleted unless otherwise changed)
                                        $OLD_VLANS{($self->exp_matchlist())[0]} = -1;
                                        exp_continue;
                                     } ],

        [ 'or \(q\)uit' =>	sub {	my $self = shift;
                                        $self->send("\r");
                                        exp_continue; 
                                    } ],

        [ $NETGEAR_ADMINPROMPT ] );
}


# ako je scripta pozvana sa "configure", onda rekonfiguriraj switch
sub reconfigure_switch() {

    # FIXME jel ovo napravljeno? postavi pvid 0/1 na 1, a ostale da stavi svaki iface u blackhole pvid 666
    #- interesantno: show vlan port all

    # sad konfiguriramo svaki PORT
    for (my $port=1; $port<=$MAXPORT; $port++) {
        if ($port>1) {
            push @TODO_PORTS, "exclude 1 $port";	# force excludamo vlan 1 sa svih portova osim prvog
        }
        print "$port=$PORTS[$port]\n";
        
        if ($PORTS[$port] eq '') {			# ako nije definiran defaultamo na unique VLAN (da se ne koristi)
            $PORTS[$port] = 'U 666'; 
        }
        
        if ($PORTS[$port] =~ /^U\s+(\d+)/) {		# untagged moze biti samo jedan!
            my $vlan=$1;
            $VLANS{$vlan} = 1;				# we need this VLAN, so create it
            $DEBUG && print "creating untagged vlan $vlan on interface $port\n";
            push @TODO_PORTS, "untagged $vlan $port";
        } elsif ($PORTS[$port] =~ /^T\s+([\d\s]+)$/) {	# tagged moze biti vise
            my @vlanlist=split(/\s/,$1);
            foreach my $vlan (@vlanlist) { 
                $DEBUG && print "tagaj $vlan na $port interface\n";
                $VLANS{$vlan} = 1;			# we need this VLAN, so create it
            }
            my $vlan_ranges = new Set::IntSpan @vlanlist;
            push @TODO_PORTS, 'tagged ' . $vlan_ranges->run_list() . " $port";
            
        } else {
            print "neznam sto sa $PORTS[$port]\n";
            exit 1;
        }
    }
    
    $DEBUG && print "Running commands:\n";

    exp_send_immediately ('vlan database');
    foreach my $vlan (sort { $a <=> $b } keys %VLANS) {
        #$DEBUG && print "setting up vlan $vlan\n";
        next if $vlan <= 3;				# VLAN 1-3 are hardcoded and cannot be deleted/created
        if ($NUKEALL) {
            exp_vlan_del ($vlan);				# always delete VLAN first to remove config
            exp_vlan_add ($vlan) if $VLANS{$vlan} > 0;		# if we need that VLAN, then (re-)create it
        } else {
            exp_vlan_add ($vlan) if !$OLD_VLANS{$vlan};		# if we need that VLAN, then create it only if it wasn't existing before
        }
    }
    exp_wait_reply ($NETGEAR_VLANPROMPT,	'exit');

    exp_wait_reply ($NETGEAR_ADMINPROMPT,	'configure');	# enter "Configure" mode
    foreach my $cmd (@TODO_PORTS) {
        if ($cmd =~ /^(exclude|tagged|untagged) (\S+) (\S+)$/) {
            if ($DRYRUN) { 
                print "DRYRUN PORT: $cmd\n";
            } else {
                exp_port_mod ($1, $2, $3);
            }
        } else {
            die "can't parse TODO_PORTS=$cmd";
        }
    }
    exp_wait_reply ($NETGEAR_CONFIGPROMPT,	'exit');	# exit "Configure" mode
    
    exit 0;
}


# print one config line
sub print_line {
    my ($vlan, $interface, $current, $configured, $tagging) = @_;
    $interface=lc($interface);
    $current=lc($current);
    $configured=lc($configured);
    $tagging=lc($tagging); chomp $tagging;
    
    my $state="";
    if ($current eq "exclude") {
        $state = ".";
    } elsif ($current eq "include") {
        if ($tagging eq "tagged") {
            $state = "T";
        } elsif ($tagging eq "untagged") {
            $state = "U";
        } else {
            die "iface=$interface vlan=$vlan nije ni tagged ni untagged, mora biti JEDAN od tih: $_";
        }
    } else {
        die "iface=$interface vlan=$vlan nije ni exclude ni include, mora biti JEDAN od tih: $_";
    }
    my $add_row = sprintf ("%5s", $state); 
    return $add_row;
}

# by default with no arguments, print current switch configuration
sub print_switch_config()
{
    # header
    print "VLAN / PORT";
    for (my $port=1; $port<=$MAXPORT; $port++) {
        printf ("%5d", $port);
    }
    print "\n";

    foreach my $vlan (sort { $a <=> $b } keys %VLANS) {
        my $row = sprintf("%-6d     ",$vlan);

        $DEBUG && print "Ide show vlan $vlan\n";
        exp_send_immediately ("show vlan $vlan");
            
        if ($DRYRUN) { 
                    print "DRYRUN print_switch_config: next\n";
                    next;
        }
        $_expect->expect ($EXPECT_TIMEOUT,
            #Interface   Current   Configured   Tagging
            #----------  --------  -----------  --------
            #0/8         Include   Include      Untagged
            #0/12        Include   Include      Tagged
            #0/13        Exclude   Autodetect   Untagged
            [ '^0\/(\d+)\s+(Include|Exclude)\s+(Include|Autodetect)\s+(Untagged|Tagged)\b' =>	
                                sub {	my $self = shift;
                                            $row .= print_line( $vlan, $self->matchlist() );
                                            exp_continue;
                                         } ],

            [ 'or \(q\)uit' =>	sub {	my $self = shift;
                                            $self->send("\r");
                                            exp_continue; 
                                        } ],

            [ 'VLAN does not exist.' ], 

            [ $NETGEAR_ADMINPROMPT ] );
            
        print "$row\n";
    }

    print "\n";
}

sub printconfig() {
    my $MAXPORTS=24;
    for my $i (1..$MAXPORTS) {
        print "P$i=$PORTS[$i]\n";
    }
    exit 0;
}

sub loadconfigfile($) {
    my ($configfile)=@_;
    my $VLANRANGE_REGEXP='[a-z_]{3,50}';
    my %VLANEXPANDED;
    my $DEBUG=0;
    $DEBUG && print "Loading config from $configfile\n";
    open (my $IN, "< $configfile") or die "Unable to load config file: $!";
    while (<$IN>) {
        chomp;
        my $l=$_;
        if (($l =~ /^#/) || ($l =~ /^\s*$/)) { next; } # ignore comments and blank lines
        $l =~ s/\s*#.*$//;
        $l =~ s/\s+$//;
        if ($l =~ /^($VLANRANGE_REGEXP)=(.*)$/) {
            $DEBUG && print "Found vlanrange $1 = $2\n";
            my ($name,$range) = ($1,$2);
            $VLANEXPANDED{"$name"}=join " ", eval $range;
            next;
        }
        while ($l =~ /($VLANRANGE_REGEXP)/) {
            my $name=$1;
            if (!defined($VLANEXPANDED{"$name"})) { 
                die "FATAL: INVALID VLANRANGE reference $name, typos?"; 
            } else {
                $l =~ s/$VLANRANGE_REGEXP/$VLANEXPANDED{"$name"}/;
            }
        }
        if ($l =~ /P(\d+)=(U|T)((?:\s+\d+\s*)+)$/) { 
            $PORTS[$1]="$2$3";
            $PORTS[$1]=~ s/\s+$//; # cleanup just in case
        } elsif ($l = /P(\d+)=\s*/) {
            $PORTS[$1]="";
        } else {
            die "FATAL FAILED syntax check:\n$l";
        }
    }
    close ($IN);
}


#########################################
##
## here goes the main
##
#########################################

exp_login();
setup_VLANS();

#use Data::Dumper; print Dumper(\%VLANS); die;

if ($#ARGV > -1) {	# imamo parametar
    if ($ARGV[0] eq "configure") {
        loadconfigfile($ARGV[1]);
        reconfigure_switch(); 
        #printconfig();
        exit 0;
    } else {
        die "nepoznati parametar";
    }
}
