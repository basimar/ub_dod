# SpeiBi.pl
# Version 1.0

use strict;
use Encode;
use FindBin;
use Mail::Sender;
use Net::Domain;
use POSIX qw(strftime);
use XML::Simple();

# ----------------------
# KONFIGURATION
# ----------------------
my $FORMAT_VERSION = '0.01';

require("$FindBin::Bin/SpeiBi.conf");
require("$FindBin::Bin/SpeiBi_Counter.pl");
my $Photo_conf = "$FindBin::Bin/SpeiBi_Fieldlist_Photocopy.conf";
my $Hold_conf  = "$FindBin::Bin/SpeiBi_Fieldlist_Hold.conf";

# ----------------------
# INITIALISIERUNG
# ----------------------
# -- aus SpeiBi.conf:
our($LVS_Print_Suffix,$LVS_Quellsystem,$LVS_Counter_Praefix,$LVS_Absenderadresse, $LVS_tab_sub_library,
    $LVS_Zieladresse, $LVS_Localhost, $LVS_SMTP_Mailhost, $LVS_Kontakte, $LVS_No_NCIP_Checkout, $LVS_Mail_no_unicode,
    $SpeiBi_Debug_Screen, $SpeiBi_Debug_File);

if ( $SpeiBi_Debug_File ) {
    $SpeiBi_Debug_Screen = 0; 
} elsif ( $SpeiBi_Debug_Screen ) {
    binmode(STDOUT, ":utf8");
}

# -- registriere Handler und Logfile
( $LVS_Print_Suffix ) or die("FEHLER: \$LVS_Print_Suffix ist in SpeiBi.conf nicht definiert.");
register_suffix($LVS_Print_Suffix, \&SpeiBi);
my $Logfile = register_logfile('speibi');
open(my $logfh,">>$Logfile") or die("cannot append to $Logfile: $!");

# -- parse Feld-Konkordanzen Aleph <-> LVS
my $Fields_Photo_Code = parse_fieldlist("$FindBin::Bin/SpeiBi_Fieldlist_Photocopy.conf");
my $Fields_Hold_Code  = parse_fieldlist("$FindBin::Bin/SpeiBi_Fieldlist_Hold.conf");

# -- oeffne Log-File zum Loggen des SMTP-Mailversands (optional fuer Debugging)
# open my $Debug_Mail, ">> /exlibris/aleph/u22_1/dsv51/scratch/maillog_bmt" or die "Can't open the debug file: $!\n";

# -- initialisiere den Mailer (Option debug schaltet Logging des SMTP-Mailversands ein)
$Mail::Sender::NO_X_MAILER = 1;
my $Mailer = Mail::Sender->new({
    from =>     $LVS_Absenderadresse,
    to =>       $LVS_Zieladresse,
    smtp =>     $LVS_SMTP_Mailhost,
    client =>   $LVS_Localhost,
#   debug =>    $Debug_Mail,
 
});
unless ( ref($Mailer) ) {
    print $logfh "FEHLER: kann Mailer nicht initialisieren: ", $Mail::Sender::Error;
    exit 1;
}

# -- parse $LVS_No_NCIP_Checkout 
my $No_NCIP_Checkout_To;
my $No_NCIP_Checkout_From_To;
my @tmp = split(/\n/,$LVS_No_NCIP_Checkout );
while ( @tmp ) {
    my $line = shift @tmp;
    $line =~ s/#.*$//;
    $line =~ s/\s+$//;
    $line =~ s/^\s+//;
    next unless ( $line ) ;
    my($von,$nach)=split(/\s+/,$line);
    if ( $von eq '*' ) {
        # kein Checkout fuer diesen Abholort:
        $No_NCIP_Checkout_To->{$nach}=1;
    } else {
        # kein Checkout fuer diese Kombination Lieferbibliothek/Abholort
        $No_NCIP_Checkout_From_To->{$von}->{$nach}=1;
    }
}

# -- initialisiere den XML-Parser
my $XML_Parser = XML::Simple->new( 
    cache => [], 
    suppressempty => '',
    forcearray => 1,
);

# -- Lookup-Tabellen sublibrary-code und -text
my($sublib_code2text,$sublib_text2code);
parse_tab_sublib();

close $logfh;


# ----------------------
# HANDLER
# ----------------------

# ----------------------
sub SpeiBi {
# ----------------------
    # Handler, aufgerufen von dodd.pl.
    # Schickt Bestellungen aus dem ALEPH-Webkatalog an LVS Server:
    # filtert nach Bestellung oder Fotokopie und stellt Fotokopiebestellungen 
    # fuer MyBib bereit (Umstellung PrintID auf '*.dd').
    #
    # input:
    #   aFiles = Liste der Dateien mit dem registrierten Suffix (arrayref)
    #
    # returns:
    #   -

    my $aFiles=shift;
    local $_;
    open(my $logfh,">>$Logfile");
INFILE:
    foreach my $infile ( @$aFiles ) {
        my $basename=File::Basename::basename($infile);
        if ( my $aleph_xml = parse_aleph_xml($infile, $logfh) ) {
            my $kopiebestellung;
            if ( $aleph_xml->{'section-03'}->[0]->{'z38-id'} ) {
                # KopieBestellung
                $kopiebestellung = 1;
            } elsif ( $aleph_xml->{'section-01'}->[0]->{'z37-id'} ) {
                # Exemplarbestellung
                $kopiebestellung = 0;
            } else {
                # Schrott:
                # Datei in .ERROR umbenennen, damit sie nicht wieder und
                # wieder vom Handler behandelt wird...
                my $copyfile = $infile  .'.ERROR';
                print $logfh "! $copyfile: kann weder z38-id noch z37-id finden.\n";
                File::Copy::move( $infile, $copyfile );
                next INFILE;
            }
            
            my $counter = SpeiBi_Counter();
            unless ( $counter ) {
                print $logfh "FEHLER: Zaehler SpeiBi_Counter() liefert keine Zahl.\n";
                next INFILE;
            }
            $counter = $LVS_Counter_Praefix . $counter;
            
            my $out_xml = format_lvs_xml($aleph_xml,$kopiebestellung,$logfh, $counter)
                or next INFILE;

            if ( $SpeiBi_Debug_File ) {
                my $outfile = $infile .'.xml';
                open(my $out,">:utf8", $outfile) or die ("cannot write $outfile: $!");
                print $out $out_xml;
                close $out;
                print "wrote $outfile\n";
            } 
            elsif ( $SpeiBi_Debug_Screen ) {
                print<<EOD;
--------------------------------------------------------------
*** START
*** [DEBUG:] bearbeite $basename

$out_xml
EOD
                if ( $kopiebestellung ) {
                    ( my $copyfile = $infile ) =~ s/$LVS_Print_Suffix$/dd/o;
                    print <<EOD;

*** [DEBUG:] KopieBestellung
*** [DEBUG:] umbenennen $infile -> $copyfile
*** END
--------------------------------------------------------------
EOD
                } else {
                    print<<EOD;

*** [DEBUG:] ExemplarBestellung
*** [DEBUG:] $basename wird ins save-Verzeichnis verschoben
*** END
--------------------------------------------------------------
EOD
                }
            } else {
                # produktive Bearbeitung
                notify_lvs($out_xml,$logfh,$kopiebestellung,$counter) 
                    or next INFILE;
                my $datestamp = strftime("%Y-%m-%d %H:%M:%S",localtime);
                if ( $kopiebestellung ) {
                    print $logfh "K $basename $datestamp\n";
                    # rename file and let the MyBib handler do the rest
                    ( my $copyfile = $infile ) =~ s/$LVS_Print_Suffix$/dd/o;
                    File::Copy::move( $infile, $copyfile );
                } else {
                    print $logfh "E $basename $datestamp\n";
                    move_to_savedir($infile);
                }
            }
        }
    }
    close $logfh;
}

# ----------------------
sub parse_aleph_xml {
# ----------------------
    # input:
    #   file:  full path of Aleph print output
    #   logfh: file handle of open log file
    #
    # returns:
    #   succes: HASH ref of XML object
    #   error:  undef

    my($file,$logfh)=@_;
    local(*F, $_);
    my $p;
    if ( open(F,"<:utf8", $file) ) {
        $_ = <F>;                   # zap first line '## - XML_XSL'
        { local $/; $_ = <F>; }
        close F;
        eval { $p = $XML_Parser->XMLin($_) };
        if ( $@ ) {
            print $logfh 'FEHLER: ' .File::Basename::basename($file) .": $@\n";  # error while parsing XML
            return undef;
        } else {
            return $p;
        }
    }
    else {
        print $logfh 'FEHLER: cannot read ' .File::Basename::basename($file) .": $!\n";
        return undef;
    }
}

# ----------------------
sub parse_fieldlist {
# ----------------------
    # lese die Konkordanzliste Aleph <-> LVS fuer hold-requests und photo-copy-requests
    #
    # returns: hash 
    #   key   = LVS-Element/LVS-Unterelement 
    #   value = Perlcode-Schnipsel zum Ansprechen des korrespondierenden Aleph-XML-Elements
    #
    #   Beispiel: 
    #       $hash->{'Exemplar/Signatur'} = "$p->{'section-02'}->[0]->{'z30-call-no'}->[0]"

    my $file = shift;
    my $hash;
    local *LIST;
    open(LIST,"<$file") or die("$0: parse_fieldlist(): cannot read $file: $!");
    while (<LIST>) {
        s/\s+$//;
        next unless ( $_ );
        next if ( /^#/ );
        my($aleph,$lvs) = split;
        my($section,$element)= split(/\//, $aleph);
        
        if ( $section eq 'section-02' ) {
            # section-02 (Exemplardaten) ist wiederholbar. Hier muss ein
            # nicht-ausgeliehendes Exemplar gefunden werden und die Daten
            # aus diesem ausgelesen werden.
            $hash->{$lvs} = qq|\$exemplar->{'$element'}->[0]|;
        } else {
            # section-01 (Bib-Daten) und section-03 (Besteller/Bestellung)
            # sind nicht wiederholbar. Hier wird jeweils das erste 
            # vorkommende Element verwendet.
            $hash->{$lvs} = qq|\$p->{'$section'}->[0]->{'$element'}->[0]|;
        }
    }
    $hash;
}

# ----------------------
sub notify_lvs {
# ----------------------
    my $out_xml = shift;            # XML Text
    my $logfh = shift;              # filehandle to open logfile
    my $kopienbestellung = shift;   # 1: Kopie, 0: Exemplar
    my $counter = shift;            # Zaehler mit Praefix
     
    my $subject;
    if ( $kopienbestellung ) {
        $subject = 'KopieBestellung ' . $counter;
    } else {
        $subject = 'ExemplarBestellung ' . $counter;
    }
    if ( $LVS_Mail_no_unicode ) {
        # wenn der Mailer UTF-8 doppelt kodiert...
        $out_xml = Encode::encode('iso-8859-1',$out_xml);
    } else {
        # prevent message "Wide character in subroutine entry at ... Mail/Sender.pm"
        $out_xml = Encode::encode('utf-8',$out_xml);
    } 
    ( ref( $Mailer->MailMsg({ 
        msg         => $out_xml,
        subject     => $subject,
        charset     => 'utf-8',
        encoding    => 'quoted-printable',
        })) )
     or print $logfh "FEHLER (Mailsystem): " .$Mail::Sender::Error ."\n";
}

# ----------------------
sub format_lvs_xml {
# ----------------------
    my $p = shift;                  # Aleph XML Objekt
    my $kopiebestellung = shift;    # 1: Kopie, 0: Exemplar
    my $logfh = shift;              # open log file handle
    my $counter = shift;            # Zaehler mit Praefix
        
    my($Fields,$TypTag,$sublib,$pickup_name,$pickup_code,$exemplar);
    
    if ( $kopiebestellung ) {
        $TypTag = 'KopieBestellung';
        $Fields = $Fields_Photo_Code;
        
        # -- bei mehreren Exemplaren wird das erste nicht-ausgeliehene
        # -- Exemplar verwendet, d.h. eines, bei dem das Element
        # -- <loan-exists> auf "N" gesetzt ist.
        foreach my $x ( @{$p->{'section-02'}} ) {
            if ( $x->{'loan-exists'}->[0] eq 'N' ) {
                $exemplar = $x;
                last;
            }
        }
        $sublib = uc($p->{'section-03'}->[0]->{'z38-filter-sub-library'}->[0]);
        $pickup_code = $p->{'section-03'}->[0]->{'z38-pickup-location'}->[0];
        $pickup_name =  $sublib_code2text->{$pickup_code} || $pickup_code;
        $Fields->{'Bestellung-Abholort-Name'} = "'$pickup_name'";
        $Fields->{'NCIP-Checkout'} = "'false'";
        my $MyBibNr = $sublib . '-' .$p->{'section-03'}->[0]->{'z38-number'}->[0];
        $Fields->{'Bestellung-MyBib-number'} = "'$MyBibNr'";
    } else {
        $TypTag = 'ExemplarBestellung';
        $Fields = $Fields_Hold_Code;
        $sublib = uc($p->{'section-01'}->[0]->{'z37-filter-sub-library'}->[0]);
        $pickup_name = $p->{'section-01'}->[0]->{'z37-pickup-location'}->[0];
        $pickup_code = $sublib_text2code->{$pickup_name} || $pickup_name;
        $Fields->{'Bestellung-Abholort-Code'} = "'$pickup_code'";
        $Fields->{'NCIP-Checkout'} = "'true'";
        if ( $No_NCIP_Checkout_To->{$pickup_code} ) {
            $Fields->{'NCIP-Checkout'} = "'false'";
        }
        if ( $No_NCIP_Checkout_From_To->{$sublib}->{$pickup_code} ) {
            $Fields->{'NCIP-Checkout'} = "'false'";
        }
    }
    my $KONTAKT = $LVS_Kontakte->{$sublib} || $LVS_Kontakte->{'DEFAULT'};
    $Fields->{'Auftrag-Admin-email'} = "'$KONTAKT'";
    
    my $NOW = strftime("%Y-%m-%d %H:%M:%S",localtime);
    $Fields->{'Auftrag-Gesendet'} = "'$NOW'";
    $Fields->{'Auftrag-Zaehler'} = "'$counter'";
    $Fields->{'Auftrag-Formatversion'}  = "'$FORMAT_VERSION'";
    $Fields->{'Auftrag-Quellsystem'}    = "'$LVS_Quellsystem'";
    
    my $txt =<<EOD;
<?xml version="1.0"?>
<Bestellung>
 <$TypTag>
EOD

    my @Fieldnames = sort keys %$Fields;
    foreach my $tag ( @Fieldnames ) { 
        my $content;
        my $rval = $Fields->{$tag} || '\'\'';
        my $perlcode = '$content = ' .$rval;
        eval "$perlcode";
        if ( $@ ) {
            print $logfh "FEHLER im Perlcode $perlcode: $@\n";
            return undef;
        }
        if ( $content = fixml($content) ) {
            $txt .= qq|   <$tag>$content</$tag>\n|;
        } else {
            $txt .= qq|   <$tag/>\n|;
        }
    }
    $txt .=<<EOD;
 </$TypTag>
</Bestellung>
EOD

    return $txt;
}

# ----------------------
sub parse_tab_sublib {
# ----------------------
    # lese die tab_sub_library.ger ein und mache eine Konkordanz
    # Code zu Text und umgekehrt. 
    local(*F,$_);
    my $file = "$FindBin::Bin/$LVS_tab_sub_library";
    open(F,"<$file") or die "cannot read $file: $!";
    while ( <F> )  {
        next if ( /^\!/ );
        s/\s+$//;
        next unless ( $_ );
        my $code = trim(substr($_,0,6));
        my $text = trim(substr($_,16,31));
        $sublib_code2text->{$code}=$text;
        $sublib_text2code->{$text}=$code;
    }
}

sub fixml {
    local $_ = shift or return '';
    # trim string
    s/\s+$//;
    s/^\s+//;
    # escape unsichere XML-Zeichen
    s/&/&amp;/g;
    s/</&lt;/g;
    s/>/&gt;/g;
    s/\"/&quot;/g;
    s/\'/&apos;/g;
    $_;
}    

sub trim {
    # remove leading and trailing whitespace
    local $_ = shift || return undef;
    s/\s+$//;
    s/^\s+//;
    $_;
}

1;

__END__
    

=head1 NAME

SpeiBi.pl - Interface zu Stoecklin LVS Server Speicherbibliothek Bueron

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript prueft fuer die registrierten Aleph 500 Bestellungen, ob es sich um 
eine Ausleihbestellung oder einen Photocopy Request handelt. Je nach Typ
wird eine entsprechende XML-Bestellung generiert und per Mail an das LVS
verschickt. Ausleihbestellungen werden anschliessend in print/save-Verzeichnis
verschoben, Photocopy Requests zu '*.dd' umbenannt, um von MyBib.pl 
behandelt zu werden.

=head1 KONFIGURATION

=head2 Aleph Konfiguration

Die folgenden Dateien in Aleph sind betroffen:

=over 1

=item tab39

Die Print ID fuer die SpeiBi-Bestellungen lautet per default 'sb'.
(Kann in SpeiBi.conf modifiziert werden.)

=item tab41

Die Print ID fuer Photocopy Requests lautet ebenfall per default 'sb'.
(Kann in SpeiBi.conf modifiziert werden.)

=back

=head2 Parsen des Aleph Printouts

Das Skript parst zwei Sorten Aleph-Output. Fuer jede Sorte ist in einer 
Konkordanzdatei definiert, (1) wie die zu extrahierenden Felder in Aleph
heissen und in in welcher "section" sie sich befinden, und (2) wie
das korrespondierende XML-Element in der Ausgabedatei heissen soll.

 Aleph-Druckdatei       Definitionsdatei
 -------------------    -------------------------------
 hold-request-slip      SpeiBi_Fieldlist_Hold.conf
 photo-request-slip     SpeiBi_Fieldlist_Photocopy.conf


=head2 Benoetigte Dateien

 SpeiBi.pl                          dieses Skript: Handler fuer SpeiBi
 SpeiBi.conf                        globale Site-Konfiguration
 SpeiBi_Counter.pl                  Subprogramm fuer Zaehler
 SpeiBi_Counter.data                Daten fuer den Zaehler
 SpeiBi_Fieldlist_Hold.conf         Feldkonkordanz Aleph - LVS (ExemplarBestellung)
 SpeiBi_Fieldlist_Photocopy.conf    Feldkonkordanz Aleph - LVS (KopieBestellung)

=head2 NCIP Checkout

Das XML-Output-Element B<NCIP-Checkout> wird nach folgender Logik gesetzt:

Fuer Kopienbestellungen ist NCIP-Checkout immer B<false>.

Fuer Exemplarbestellungen ist NCIP-Checkout immer B<true>, ausser wenn
ein bestimmter Abholort oder eine Kombination von besitzender Bibliothek
und Abholort in der Konfigurationsdatei SpeiBi.conf explizit ausgeschlossen
wird.

=head2 Logfile

Wenn der dod-Daemon neu gestartet wird, wird ein neues Logfile mit
dem Namen B<speibi-YYYY-Mon-DD.log> angelegt. Die Logdatei enthaelt
Informationen ueber Start und Stop des Daemons, diverse Fehlermeldungen
und eine Zeile fuer jede bearbeitete Datei, mit Zeitstempel der
Bearbeitung. 

 E druck-57235828.bssbisb 2016-04-18 18:38
 K druck-57235844.bssbksb 2016-04-18 18:45

Ein 'E' vor dem Dateinamen bedeutet 'Exemplarbestellung', ein
'K' 'Kopienbestellung'.

=head1 DETAILS

=head2 Code und Bezeichnung des Abholorts

Das Printformular fuer Exemplarbestellung liefert nur den B<Namen> des
Abholorts (z37-pickup-location), das Formular fuer die Kopienbestellung
nur den B<Code> (z38-pickup-location).

Damit wir fuer das LVS in jeder Bestellung sowohl <Bestellung-Abholort-Name>
wie <Bestellung-Abholort-Code> liefern koennen, macht das Programm eine
Konkordanz zwischen Code und Bezeichnung der Sublibraries in
tab_sub_library.ger und holt von dort das jeweils fehlende Teil.

B<Achtung>: wenn mehrere Codes in der tab_sub_library dieselbe Bezeichnung
haben, dann wird beim Aufloesen der Bezeichnung der jeweils letzte 
Code verwendet. Wenn das nicht passt und man die orignale tab_sub_library
nicht aendern kann oder will, dann kann man eine Kopie der tab_sub_library
anlegen und entsprechend anpassen. Der Pfad zur Datei ist in der
SpeiBi.conf konfigurierbar ($LVS_tab_sub_library).

=head2 Probleme mit dem Zeichensatz

Tests haben gezeigt, dass die korrekte Darstellung von XML als Inline-Text
und mit Unicode-Zeichensatz (kodiert als UTF-8) vom Zusammenspiel zwischen
Mail::Sender, dem lokalen SMTP-Mailserver und dem empfangenden IMAP-Mailserver
abhaengt, aber vermutlich auch vom Mondstand oder vom Dollarkurs.

Der folgende Workaround scheint zu funktionieren:
Wenn die Konfigurationsvariable $LVS_Mail_no_unicode gesetzt ist,
wird der Mailtext vor dem Versand in ISO-8859-1 konvertiert, damit
er vom Mailer korrekt als UTF-8 verschickt werden kann. Zeichen, die
nicht in ISO-8859-1 definiert sind, gehen in diesem Fall verloren.

Ob diese Variable gesetzt werden muss, kann nur Trial und Error
zeigen. Der gegenwaertige Stand ist

 Bibliothek    LVS_Mail_no_unicode
 ------------- ---------------------
 UB Basel      0
 ZB Zuerich    0
 ZHB Luzern    1


=head1 HISTORY

 23.02.2015 beta 0.0
 27.02.2015 beta 0.1
 22.04.2015 beta 0.2 Mailer implementiert. Erweiterte Logik fuer NCIP-Checkout / ava
 18.05.2015 beta 0.3 forcearray fuer XML-Parser / ava
 05.06.2015 beta 0.4 $LVS_Mail_no_unicode / ava
 09.06.2015 beta 0.5 Doku erweitert / ava
 12.06.2015 beta 0.6 Kopienbestellung generiert <Bestellung-MyBib-number> / ava
 19.06.2015 beta 0.7 Besitzende-Bibliotek-email > Auftrag-admin-email / pm
 01.03.2016 beta 0.8 Kopienbestellung nur mit nicht-ausgeliehenem Exemplar / ava
 18.04.2016 1.0 date stamp in logfile / ava

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2016 by University Library Basel, Switzerland

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.9 or,
at your option, any later version of Perl 5 you may have available.

=head1 AUTHOR

Idee von meta.walser@ethz.ch. 
Weiterentwickelt fuer IDS Basel Bern von Andres von Arx und Bernd Luchner

=head1 SEE ALSO

Das Skript verwendet folgende Perl-Module ausserhalb der Standard-Distribution:
Mail::Sender, XML::Simple

=cut
