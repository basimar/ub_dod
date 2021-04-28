# SpliMail.pl

use strict;
use FindBin;
use POSIX qw/strftime/;

# -------------------------
# INITIALISIERUNG
# -------------------------
local *CONF;
my $ConfFile = $FindBin::Bin ."/SplitMailA100.conf";
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
    my ( $suffix, $email, $print, $print3, $oldform, $newform ) = split;
    $Config->{"\.$suffix"}->{email} = "\.$email";
    $Config->{"\.$suffix"}->{print} = "\.$print";
    $Config->{"\.$suffix"}->{print3} = "\.$print3";
    $Config->{"\.$suffix"}->{oldform} = "$oldform";
    $Config->{"\.$suffix"}->{newform} = "$newform";
}
foreach my $suffix ( keys %$Config ) {
    register_suffix( $suffix, \&SplitMailA100 );
}
my $Logfile = register_logfile('splitMailA100');


# -------------------------
# HANDLE
# -------------------------
sub SplitMailA100 {
    my $aFiles = shift;
    local(*IN,*OUT,*LOG,$_);
    open(LOG,">>$Logfile");

    foreach my $infile ( @$aFiles ) {
        my($print_suffix,$email_suffix,$print3_suffix,$oldform,$newform,$print3_file,$print_file,$email_file,$nPrint,$nEmail,$nPrint3);
        foreach my $suffix ( keys %$Config ) {
            if ( $infile =~ /$suffix$/ ) {
                $print_suffix = $Config->{$suffix}->{print};
                $email_suffix = $Config->{$suffix}->{email};
                $print3_suffix = $Config->{$suffix}->{print3};
                $newform = $Config->{$suffix}->{newform};
                $oldform = $Config->{$suffix}->{oldform};
                ( $print_file = $infile ) =~ s/$suffix$/$print_suffix/;
                ( $print3_file = $infile ) =~ s/$suffix$/$print3_suffix/;
                ( $email_file = $infile ) =~ s/$suffix$/$email_suffix/;
                last;
            }
        }
        unless ( open(IN,"<$infile") ) {
            print LOG "FEHLER: cannot read $infile: $!\n";
            next;
        }
        my $print='';
        my $print3='';
        my $email='';
        my $tmp='';
        while ( <IN> ) {
            if ( (/^## - XML_XSL/ && $tmp) or eof ) {
                if ( eof ) {
                    $tmp .= $_;
                }
                if ( $tmp =~ m|\r?\n\r?\n<email-address>.+</email-address>| ) {
                    $nEmail++;
                    $email .= $tmp;
                    $tmp = '';
                } else {
                    if ( $tmp =~ m|<form-name>overdue-letter-3</form-name>| ) { 
                        $nPrint3++;
                        $print3 .= $tmp;
                        my $oldformstring = "<form-format>$oldform</form-format>";
                        my $newformstring = "<form-format>$newform</form-format>";
                        $print3 =~ s/$oldformstring/$newformstring/g;
                        $tmp = '';
                    } else {
                        $nPrint++;
                        $print .= $tmp;
                        $tmp = '';
                    }
                }
            }
            $tmp .= $_;
        }
        close IN;
        if ( $print ) {
            if ( open(OUT,">$print_file") ) {
                print OUT $print;
                close OUT;
            } else {
                print LOG "FEHLER: cannot write $print_file: $!";
                next;
            }
        }
        if ( $print3 ) {
            if ( open(OUT,">$print3_file") ) {
                print OUT $print3;
                close OUT;
            } else {
                print LOG "FEHLER: cannot write $print3_file: $!";
                next;
            }
        }
        if ( $email ) {
            if ( open(OUT,">$email_file") ) {
                print OUT $email;
                close OUT;
            } else {
                print LOG "FEHLER: cannot write $email_file: $!";
                next;
            }
        }
        print LOG strftime("%H:%M:%S - ",localtime), File::Basename::basename($infile),
            sprintf(" - email: %d - print: %d - print3: %d\n", $nEmail, $nPrint, $nPrint3);
        move_to_savedir($infile);
    }
    close LOG;
}

1;

__END__

=head1 NAME

SplitMail.pl - separiere Aleph 500 Printoutput in Email und Druck

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript parst Aleph 500 Druckauftraege mit den in der Konfigurationsdatei
B<SplitMail.conf> definierten Print IDs (= Dateisuffixen).
Es generiert separate Druckauftraege fuer Email und fuer Druck, mit jeweils
separaten Print IDs. Die Originaldatei wird danach ins save Verzeichnis verschoben.

=head1 HISTORY

 0.01 - 30.11.2006: Aleph V.16
 0.02 - 29.11.2007: Aleph V.18 - neue Erkennungskriterien fuer Email in Eingabedatei

=head1 AUTHOR

Andres von Arx

=head1 SEE ALSO

Konfigurationsdatei F<SplitMail.conf>. 

=cut
