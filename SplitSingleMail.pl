# SplitSingleMail.pl

use strict;
use FindBin;
use POSIX qw/strftime/;

# -------------------------
# INITIALISIERUNG
# -------------------------
local *CONF;
my $ConfFile = $FindBin::Bin ."/SplitSingleMail.conf";
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
    my ( $suffix, $email ) = split;
    $Config->{"\.$suffix"}->{email} = "\.$email";
    
}
foreach my $suffix ( keys %$Config ) {
    register_suffix( $suffix, \&SplitSingleMail );
}
my $Logfile = register_logfile('splitSingleMail');


# -------------------------
# HANDLE
# -------------------------
sub SplitSingleMail {
    my $aFiles = shift;
    local(*IN,*OUT,*LOG,$_);
    open(LOG,">>$Logfile");

    foreach my $infile ( @$aFiles ) {
        my($old_suffix,$email_suffix,$email_file,$nEmail);
        foreach my $suffix ( keys %$Config ) {
            if ( $infile =~ /$suffix$/ ) {
                $email_suffix = $Config->{$suffix}->{email};
                $old_suffix = $suffix;
                last;
            }
        }
        unless ( open(IN,"<$infile") ) {
            print LOG "FEHLER: cannot read $infile: $!\n";
            next;
        }
        my $print='';
        my $email='';
        my $tmp='';
        while ( <IN> ) {
            if ( (/^## - XML_XSL/ && $tmp) or eof ) {
                if ( eof ) {
                    $tmp .= $_;
                }
                $nEmail++;
                ( $email_file = $infile ) =~ s/$old_suffix/\.$nEmail$email_suffix/;
                if ( open(OUT,">$email_file") ) {
                    print OUT $tmp;
                    close OUT;
		} else {
                    print LOG "FEHLER: cannot write $email: $!";
                    next;
                }	
		$tmp = '';
            }
            $tmp .= $_;
        }
        
        close IN;
        
        print LOG strftime("%H:%M:%S - ",localtime), File::Basename::basename($infile),
            sprintf(" - email: %d \n", $nEmail );
        move_to_savedir($infile);
    }
    close LOG;
}

1;

__END__

=head1 NAME

SplitSingleMail.pl - separiert Aleph 500 Email-Printoutput in einzelne Dateien  

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript parst Aleph 500 Druckauftraege mit den in der Konfigurationsdatei
B<SplitSingleMail.conf> definierten Print IDs (= Dateisuffixen).
Es generiert fuer jede Email eine einzelne Druckdatei
Die Originaldatei wird danach ins save Verzeichnis verschoben.

=head1 HISTORY

 0.01 - 22.04.2015: Erstellt durch Modifikation von SplitMail.pl

=head1 AUTHOR

Basil Marti

=head1 SEE ALSO

Konfigurationsdatei F<SplitSingleMail.conf>. 

=cut
