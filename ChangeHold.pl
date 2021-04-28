# ChangeHold.pl

use strict;
use FindBin;
use POSIX qw/strftime/;

# -------------------------
# INITIALISIERUNG
# -------------------------
local *CONF;
my $ConfFile = $FindBin::Bin ."/ChangeHold.conf";
my $conf;
open(CONF,"< $ConfFile") or die("cannot read $ConfFile: $!");
{ local $/; $conf=<CONF>; }
close CONF;
my $Config;
my @tmp = split(/\n/,$conf);
while ( @tmp ) {
    local $_ = shift @tmp;
    s/\s+$//;
    next if ( /^#/ );
    next unless ( $_);
    my ($suffix, $default, $user, $format, $user_suffix) = split;
    $Config->{"\.$suffix"}->{default_printid} = $default;
    $Config->{"\.$suffix"}->{z37id}->{$user} = {
            format => $format,
            printid => $user_suffix,
        };
}
foreach my $suffix ( keys %$Config ) {
    register_suffix( $suffix, \&ChangeHold );
}
my $Logfile = register_logfile('changeHold');

# -------------------------
# HANDLE
# -------------------------
sub ChangeHold {
    my $aFiles = shift;
    local(*IN,*OUT,*LOG,$_);
    open(LOG,">>$Logfile");

    foreach my $infile ( @$aFiles ) {
        foreach my $suffix ( keys %$Config ) {
            if ( $infile =~ /$suffix$/ ) {
                my $printid;
                unless ( open(IN,"<$infile") ) {
                    print LOG "FEHLER: cannot read $infile: $!\n";
                    next;
                }
                { local $/; $_ = <IN>; }
                close IN;
                my($user) = m|^<z37-id>(.*)</z37-id>|m;
                my $conf = $Config->{$suffix}->{z37id}->{$user};
                unless ( $conf ) {
                    # -- default
                    $printid = $Config->{$suffix}->{default_printid};
                } else {
                    # -- Spezialfall fuer den Benutzer 'user'
                    my $format = $conf->{format};
                    s|<form-format>(.*)</form-format>|<form-format>$format</form-format>|;
                    unless ( open(OUT,">$infile") ) {
                        print LOG "FEHLER: cannot write $infile: $!\n";
                        next;
                    }
                    print OUT $_;
                    close OUT;
                    $printid = $conf->{printid};
                }
                ( my $outfile  = $infile ) =~ s/$suffix/.$printid/;
                my $ret = rename($infile,$outfile);
                print LOG strftime("%H:%M:%S - ",localtime), File::Basename::basename($infile),
                    ' -> ', File::Basename::basename($outfile), "\n";
            }
        }
    }
}

1;

__END__

=head1 NAME

ChangeHold.pl - bearbeite hold-request-slips nach bestimmten Regeln

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript parst Aleph 500 hold-request-slips mit den in der Konfigurationsdatei
B<ChangeHold.conf> definierten Print IDs (= Dateisuffixen). Fuer definierte Benutzer
wird die Formatnummer des Formulars geaendert und das Formular mit der angebenen
neuen Print ID versehen. Fuer alle anderen Benutzer erhaelt das Formular bloss
eine neue Print ID.

=head1 HISTORY

 0.01 - 27.01.2009: Aleph V.18

=head1 AUTHOR

Andres von Arx

=head1 SEE ALSO

Konfigurationsdatei F<ChangeHold.conf>.

=cut
