#!/usr/bin/perl -wT
my @PORTS;
my $VLANRANGE_REGEXP='[a-z_]{3,50}';
my %VLANRANGE;
my $DEBUG=0;
open (my $IN, "< example.cfg");
while (<$IN>) {
    chomp;
    my $l=$_;
    if (($l =~ /^#/) || ($l =~ /^\s*$/)) { next; } # ignore comments and blank lines
    $l =~ s/\s*#.*$//;
#    if ($l =~ /^($VLANRANGE_REGEXP)=(\d+\.\.\d+)/) {
    if ($l =~ /^($VLANRANGE_REGEXP)=(.*)$/) {
        $DEBUG && print "Found vlanrange $1 = $2\n";
        my ($name,$range) = ($1,$2);
        $VLANRANGE{"$name"}=$range;
        $VLANEXPANDED{"$name"}=join " ", eval $range;
        $DEBUG && print "VLANRANGE=".$VLANRANGE{"$name"}."\n";
        next;
    }
    while ($l =~ /($VLANRANGE_REGEXP)/) {
        my $name=$1;
        if (!defined($VLANRANGE{"$name"})) { 
            die "FATAL: INVALID VLANRANGE reference $name, typos?"; 
        } else {
            $l =~ s/$VLANRANGE_REGEXP/$VLANEXPANDED{"$name"}/;
        }
    }
    print "$l\n";
}
close ($IN);
