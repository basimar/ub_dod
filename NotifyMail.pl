# NotifyMail.pl

use strict;
use Encode;
use File::Basename;
use File::Copy;
use FindBin;
use Mail::Sender;
use POSIX qw(strftime);
use XML::Simple();

# ----------------------
# KONFIGURATION
# ----------------------
my $Debug       = 0;  # if true, do not send mail, do not move files, print to stdout
my $LocalHost   = 'aleph.unibas.ch';
my $MailFrom    = 'IDS Basel Bern';
my $MailMessage = "Eine Aleph-Bestellung wird ausgedruckt.\n\n%s\n";   # %s = Signatur(en)
my $MailSubject = 'Aleph-Bestellung';

# -------------------------
# INITIALISIERUNG
# -------------------------
local *CONF;
my $ConfFile = $FindBin::Bin ."/NotifyMail.conf";
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
    my ( $suffix, $rename, $email ) = split;
    $Config->{"\.$suffix"}->{rename} = "\.$rename";
    $Config->{"\.$suffix"}->{email} = $email;
}
foreach my $suffix ( keys %$Config ) {
    register_suffix( $suffix, \&NotifyMail );
}
my $Logfile = register_logfile('NotifyMail');
local *LOG;
open(LOG,">>$Logfile") or die("cannot append to $Logfile: $!");

# -- Mailer
$Mail::Sender::NO_X_MAILER = 1;
my $Mailer = Mail::Sender->new({
    from =>     $MailFrom,
    subject =>  $MailSubject,
    smtp =>     '',
    client =>   $LocalHost,
    charset =>  'ISO-8859-1',
    encoding => '8BIT',
});
unless ( ref($Mailer) ) {
    print LOG "FEHLER: kann Mailer nicht initialisieren: ", $Mail::Sender::Error;
    exit 1;
}
# -- XML Parser
# don't cache parsed files; display empty elements as empty string
my $XML_Parser = XML::Simple->new( cache => [], suppressempty => '');
close LOG;


# -------------------------
# HANDLE
# -------------------------
sub NotifyMail {
    my $aFiles=shift;
    local(*LOG,$_);
    open(LOG,">>$Logfile");
    my $ofh=select(LOG);
    my $logfh=select($ofh);

    foreach my $infile ( @$aFiles ) {
        my($outfile,$mailto,$mailmsg);
        my $basename=File::Basename::basename($infile);
        foreach my $suffix ( keys %$Config ) {
            my $rename_suffix = $Config->{$suffix}->{rename};
            if ( $infile =~ /$suffix$/ ) {
                $outfile = $infile;
                $outfile =~ s|$suffix$|$rename_suffix|;
                $mailto  = $Config->{$suffix}->{email};
                last;
            }
        }
        if ( my $signatur = parse_xml_output($infile,$logfh) ) {
            $mailmsg = sprintf($MailMessage, $signatur);
        }
        if ( $Debug ) {
            my $line = '-' x 50 ."\n";
            print<<EOD;
---------------------------------------------------
input:   $infile
move to: $outfile
---------------------------------------------------
mail to: $mailto
from:    $MailFrom
subject: $MailSubject
---------------------------------------------------
$mailmsg
EOD
            print LOG "+ $basename\n";
        } else {
            if ( ref( $Mailer->MailMsg({ msg => $mailmsg, to => $mailto })) ) {
                print LOG "+ $basename\n";
                File::Copy::move( $infile, $outfile );
            }
            else {
                print LOG "! $basename: " .$Mail::Sender::Error ."\n";
            }
        }
    }
    close LOG;
}

sub parse_xml_output {
    # input:
    #   file:  full path of Aleph print output
    #   logfh: file handle of open log file
    #
    # returns:
    #   - string: Signatur [\n Signatur2] \n
    #   - undef if some error occurred

    my($file,$logfh)=@_;
    local(*F, $_);
    my($p,$ret);
    if ( open(F,"<$file") ) {
        $_ = <F>;                   # zap first line '## - XML_XSL'
        { local $/; $_ = <F>; }
        close F;
        eval { $p = $XML_Parser->XMLin($_) };
        if ( $@ ) {
            print $logfh 'FEHLER: ' .File::Basename::basename($file) .": $@\n";  # error while parsing XML
            return undef;
        }
        # my $ret = "Formular: " .$p->{'form-name'} ."\n"  # Formularname
        my $ret = "Signatur:  " .$p->{'section-01'}->{'z30-call-no'} ."\n";
        if (  $p->{'section-01'}->{'z30-call-no-2'} ) {
            $ret .= "Signatur2: " .$p->{'section-01'}->{'z30-call-no-2'} ."\n";
        }
        Encode::from_to($ret,'utf8','latin1');
        return $ret;
    }
    else {
        print $logfh 'FEHLER: cannot read ' .File::Basename::basename($file) .": $!\n";
        return undef;
    }
}

1;

__END__

=head1 NAME

NotifyMail.pl - schicke eine Email, wenn ein Aleph 500 Printoutput bereitsteht.

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript parst Aleph 500 Druckauftraege mit den in der Konfigurationsdatei
B<NotifyMail.conf> definierten Print IDs (= Dateisuffixen). Es mailt eine
Meldung, dass ein Auftrag ausgedruckt wird und benennt danach die Druckdatei
um, wie in der Konfigurationsdatei angegeben. Die Mail enthaelt die Signatur(en).

=head1 HISTORY

 0.01 - 20.09.2011: Aleph V.20

=head1 AUTHOR

Andres von Arx

=head1 SEE ALSO

Konfigurationsdatei F<NotifyMail.conf>.

=cut
