# MyBib.pl
# Version 2.04

use strict;
use Encode;
use FindBin;
use Mail::Sender;
use POSIX qw(strftime);
use XML::Simple();

# ----------------------
# KONFIGURATION
# ----------------------
require("$FindBin::Bin/MyBib.conf");
our($MyBib_Localhost, $MyBib_SMTP_Mailhost, $MyBib_Mail_From, $MyBib_Mail_Subject, 
    $MyBib_Input_Suffix, $MyBib_Print_Suffix, $MyBib_Allowed_Pickup_Locations,
    $MyBib_Requester_Id, $MyBib_conf, $MyBib_Debug);

# ----------------------
# INITIALISIERUNG
# ----------------------
register_suffix($MyBib_Input_Suffix, \&MyBib);
my $Logfile = register_logfile('myBib');
open(my $logfh,">>$Logfile") or die("cannot append to $Logfile: $!");

# -- Konfiguration
my $MyBibConfig;
my @tmp = split(/\n/,$MyBib_conf);
while ( @tmp ) {
    local $_ = shift @tmp;
    s/\s+$//;
    next if ( /^#/ );
    next unless ( $_ );
    my ($alephlib,$mybib_libcode,$suffix,$domain,$requester_email,$host_email)=split(/\s*\|\s*/);
    $MyBibConfig->{$alephlib}->{signatur_suffix}    = $suffix;
    $MyBibConfig->{$alephlib}->{mybib_libcode}      = $mybib_libcode;
    $MyBibConfig->{$alephlib}->{mybib_domain}       = $domain;
    $MyBibConfig->{$alephlib}->{requester_email}    = $requester_email;
    $MyBibConfig->{$alephlib}->{host_email}         = $host_email;
}
my %MyBib_Allowed_Pickup_Locations = map {$_=>1} @$MyBib_Allowed_Pickup_Locations;

# -- Mailer
$Mail::Sender::NO_X_MAILER = 1;
my $Mailer = Mail::Sender->new({
    from =>     $MyBib_Mail_From,
    subject =>  $MyBib_Mail_Subject,
    smtp =>     $MyBib_SMTP_Mailhost,
    client =>   $MyBib_Localhost,
    charset =>  'ISO-8859-1',
    encoding => '8BIT',
});
unless ( ref($Mailer) ) {
    print $logfh "FEHLER: kann Mailer nicht initialisieren: ", $Mail::Sender::Error;
    exit 1;
}

# -- XML Parser
my $XML_Parser = XML::Simple->new( 
    cache => [], 
    suppressempty => '',
    forcearray => 1,
    );
close $logfh;

# ----------------------
# HANDLER
# ----------------------

sub MyBib {
    # Handler, aufgerufen von dodd.pl.
    # Schickt Fotokopiebestellungen aus dem ALEPH-Webkatalog an MyBib Server:
    # filtert nach z38_pickup_location und stellt Fotokopiebestellungen, die NICHT
    # via MyBib bearbeitet werden, fuer den ALEPH-Taskmanager bereit (Umstellung PrintID)
    #
    # input:
    #   aFiles = Liste der Dateien mit dem registrierten Suffix (arrayref)
    #
    # returns:
    #   -

    my $aFiles=shift;
    local $_;

    open(my $logfh,">>$Logfile");
    foreach my $infile ( @$aFiles ) {
        my $basename=File::Basename::basename($infile);
        my $dod_ok=0;
        my $datestamp = strftime("%Y-%m-%d %H:%M:%S",localtime);
        if ( my $xml = mybib_parse_xml($infile, $logfh) ) {
            # it's an email delivery request
            my $request = mybib_format_request($xml);
            my $mailmsg = $request->{mailmsg};
            $mailmsg = Encode::encode('iso-8859-1',$mailmsg);
            my $mailto  = $request->{mailto};
            if ( $MyBib_Debug ) {
                my $line = '-' x 50 ."\n";
                print $line, "file: $basename\nmail to: $mailto\n", $line, $mailmsg, "\n";
                print $logfh "+ $basename $datestamp\n";
            } else {
                if ( ref( $Mailer->MailMsg({ msg => $mailmsg, to => $mailto })) ) {
                    $dod_ok=1;
                    print $logfh "+ $basename $datestamp\n";
                }
                else {
                    print $logfh "! $basename  $datestamp: " .$Mail::Sender::Error ."\n";
                }
            }
        }
        else {
            # it's a paper delivery request
            print $logfh "- $basename  $datestamp\n";
        }
        if ( $dod_ok ) {
            # everything done
            move_to_savedir($infile);
        } elsif ( ! $MyBib_Debug )  {
            # rename file and let Aleph do the rest
            ( my $copyfile = $infile ) =~ s/${MyBib_Input_Suffix}$/${MyBib_Print_Suffix}/o;
            File::Copy::move( $infile, $copyfile );
        }
    }
    close $logfh;
}

sub elem {
    # return the *first* element in an array of Aleph-XML-Elements
    my($p,$section,$element)=@_;
    my $content;
    eval { $content = $p->{$section}->[0]->{$element}->[0] };
    $content;
}

sub mybib_parse_xml {
    # input:
    #   file:  full path of Aleph print output
    #   logfh: file handle of open log file
    #
    # returns:
    #   - HASH ref of printout object if the print output is an EMAIL order
    #   - undef if the print output is not an EMAIL order or if some error occurred

    my($file,$logfh)=@_;
    local(*F, $_);
    my $p;
    if ( open(F,"<$file") ) {
        $_ = <F>;                   # zap first line '## - XML_XSL'
        { local $/; $_ = <F>; }
        close F;
        eval { $p = $XML_Parser->XMLin($_) };
        if ( $@ ) {
            print $logfh 'FEHLER: ' .File::Basename::basename($file) .": $@\n";  # error while parsing XML
            return undef;
        }
        my $pickup = elem($p,'section-03','z38-pickup-location');
        if ( $MyBib_Allowed_Pickup_Locations{$pickup} ) {
            return $p;
        } else {
            return undef;
        }
    }
    else {
        print $logfh 'FEHLER: cannot read ' .File::Basename::basename($file) .": $!\n";
        return undef;
    }
}

sub mybib_format_request {

    # formatiert die Mail an den MyBib-Server
    #
    # input:
    #   $p = hashref-Verson der XML-Struktur des Aleph Kopierauftrags
    #   section-01: bibliographische info (kurztitel)
    #   section-02: exemplardaten
    #   section-03: benutzerdaten
    #
    # returns:
    #   $ret = Hashref mit den Keys
    #   $ret->{mailmsg} = Inhalt der Mail
    #   $ret->{mailto}  = Emailadresse des MyBib Hosts
    #
    # ACHTUNG:
    #   XML::Simple wandelt die XML-Daten nach ISO-8859-1 um

    my $p=shift;
    my $aleph_sublib = elem($p,'section-03','z38-filter-sub-library');

    # -- bei mehreren Exemplaren wird das erste nicht-ausgeliehene
    # -- Exemplar verwendet, d.h. eines, bei dem das Element
    # -- <loan-exists> auf "N" gesetzt ist.
    my $exemplar;
    foreach my $x ( @{$p->{'section-02'}} ) {
        if ( $x->{'loan-exists'}->[0] eq 'N' ) {
            $exemplar = $x;
            last;
        }
    }
    my $signatur = mybib_normalize_signatur($exemplar);
    if ( $MyBibConfig->{$aleph_sublib}->{signatur_suffix} ) {
        $signatur .= ' ' .$MyBibConfig->{$aleph_sublib}->{signatur_suffix};
    }
    my $vars = {
        ATITLE          => elem($p,'section-03','z38-title'),
        AUFTRAG         => elem($p,'section-03','z38-number'),
        AUT             => elem($p,'section-03','z38-author'),
        BOR_STATUS      => elem($p,'section-03','z305-bor-status'),
        COLLECTION      => elem($p,'section-03','z38-filter-collection'),
        DESCRIPTION     => $exemplar->{'z30-description'}->[0],
        ITEMBARCODE     => $exemplar->{'z30-barcode'}->[0],
        JTITLE          => elem($p,'section-01','z13-title'),
        PAGES           => elem($p,'section-03','z38-pages'),
        PICKUP          => elem($p,'section-03','z38-pickup-location'),
        REQUESTER_EMAIL => $MyBibConfig->{$aleph_sublib}->{requester_email},
        REQUESTER_ID    => $MyBib_Requester_Id,
        SIGNATUR        => $signatur,
        SUBLIB          => $MyBibConfig->{$aleph_sublib}->{mybib_libcode},
        SUBLIB_NAME     => $MyBibConfig->{$aleph_sublib}->{mybib_domain},
        TIME1           => strftime("%Y%m%d%H%M", localtime),
        UADDR           => mybib_normalize_address($p),
        UEMAIL          => elem($p,'section-03','email-address'),
        UID             => elem($p,'section-03','z302-id'),
        UNAME           => elem($p,'section-03','z302-address-0'),
        COMMENT         => elem($p,'section-03','z38-note-1') 
                            .' ' .elem($p,'section-03','z38-note-2')
                            .' ' .elem($p,'section-03','z38-additional-info'),
     };
    # trimme Kommentarfeld
    $vars->{COMMENT} =~ s/\s+$//;
    $vars->{COMMENT} = substr($vars->{COMMENT},0,255);  
    
    # falls mehrere Email-Adressen eingetragen sind: nimm nur die erste!
    $vars->{UEMAIL} =~ s/\,.*$//;
    $vars->{UEMAIL} =~ s/\;.*$//;

    my $msg = mybib_template();
    foreach my $key ( keys %$vars ) {
        my $val = $vars->{$key};
        my $pat = quotemeta("%%$key%%");
        $msg =~ s|$pat|$val|g;
    }
    my $ret;
    $ret->{mailmsg} = $msg;
    $ret->{mailto} = $MyBibConfig->{$aleph_sublib}->{host_email};
    $ret;
}

# ----------------------
# Email Template
# ----------------------
sub mybib_template {
    my $ret=<<'EOD';
message-type: REQUEST
transaction-id:
transaction-group-qualifier: %%SUBLIB%% %%AUFTRAG%%
transaction-qualifier: 0
service-date-time: %%TIME1%%
requester-id: %%REQUESTER_ID%%
requester-note: %%SUBLIB_NAME%% %%AUFTRAG%% %%UID%% %%COMMENT%%
requester-email-address: %%REQUESTER_EMAIL%%
country-delivery-target: CH
responder-id: %%SUBLIB_NAME%%
responder-sub-id: %%SUBLIB%%
responder-address: %%COLLECTION%%
client-id:
client-name: %%UNAME%%
client-identifier: %%UID%%
customer-no: %%UID%%
transaction-type: SIMPLE
delivery-address:
del-email-address: %%UEMAIL%%
del-postal-address: %%UNAME%%
%%UADDR%%
del-notes: %%COMMENT%%
delivery-service: %%PICKUP%%
delivery-service-format: PDF
del-status-level-user: ALL
del-status-level-requester: NONE
billing-address:
bill-method: INVOICE
bill-invoice-type: SINGLE
bill-postal-address: %%UNAME%%
%%UADDR%%
requester-group: %%BOR_STATUS%%
ill-service-type: COPY
item-id:
item-type: SERIAL
item-call-number: %%SIGNATUR%%
item-title: %%JTITLE%%
item-author-of-article: %%AUT%%
item-title-of-article: %%ATITLE%%
item-pagination: %%PAGES%%
item-verification-reference-source: %%AUFTRAG%%
item-volume-issue: %%COMMENT%%
supplemental-item-description: %%DESCRIPTION%%
iwc-lls-medium-number: %%ITEMBARCODE%%
EOD
}

sub mybib_normalize_signatur {
    my $exemplar = shift;
    my $sig = $exemplar->{'z30-call-no'}->[0];
    my $sig2 = $exemplar->{'z30-call-no-2'}->[0];
    if ( $sig2 ) {
        $sig .= ' --- ' . $sig2;
    }
    return $sig;
}

sub mybib_normalize_address {
    my $p = shift;
    my @tmp;
    for ( my $i=1 ; $i <= 4 ; $i++ ) {
        if ( my $tmp = elem($p,'section-03', "z302-address-$i") ) {
            push(@tmp," $tmp");
        }
    }
    return join("\n",@tmp);
}

1;

__END__

=head1 NAME

MyBib.pl - Interface zu ImageWare MyBib DOD Server

=head1 SYNOPSIS

Das Skript wird von dodd.pl aufgerufen.

=head1 DESCRIPTION

Das Skript prueft fuer die registrierten Aleph 500 Photocopy Requests, welcher
Abholort angegeben wird. Falls dieser WEB pder POST entspricht, werden die
benoetigten Informationen aus dem Request extrahiert und als Email an den Document
Delivery Server der ZB Bern geschickt. Falls NICHT, wird der Request
umbenannt; er wird dann auf gewohnte Weise vom Aleph Taskmanager lokal
ausgedruckt.

Unterstuetzt wird das DOD System I<MyBib> von I<ImageWare Components
GmbH>, http://www.imageware.de .

=head2 Template fE<uuml>r Emails

Das Email-Format entspricht grob dem Format von Subito, http://www.subito-doc.de .

Die Email wird im Code mit einem B<Template> vorformatiert. Die
variablen Textteile werden im Template durch Stellvertreter markiert,
d.h. durch Begriffe, die zwischen doppelten Prozentzeichen stehen
(Beispiel: C<%%AUT%%>). Das Programm extrahiert die benoetigte Information
aus dem Aleph 500 Kopierauftrag (z38) und setzt sie in das Template ein.

 message-type: REQUEST
 transaction-id:
 transaction-group-qualifier: %%SUBLIB%% %%AUFTRAG%%
 transaction-qualifier: 0
 service-date-time: %%TIME1%%
 requester-id: %%REQUESTER_ID%%
 requester-note: %%SUBLIB_NAME%% %%AUFTRAG%% %%UID%% %%COMMENT%%
 requester-email-address: %%REQUESTER_EMAIL%%
 country-delivery-target: CH
 responder-id: %%SUBLIB_NAME%%
 responder-sub-id: %%SUBLIB%%
 responder-address: %%COLLECTION%%
 client-id: 
 client-name: %%UNAME%%
 client-identifier: %%UID%%
 customer-no: %%UID%%
 transaction-type: SIMPLE
 delivery-address:
 del-email-address: %%UEMAIL%%
 del-postal-address: %%UNAME%%
 %%UADDR%%
 del-notes: %%COMMENT%%
 delivery-service: %%PICKUP%%
 delivery-service-format: PDF
 del-status-level-user: ALL
 del-status-level-requester: NONE
 billing-address:
 bill-method: INVOICE
 bill-invoice-type: SINGLE
 bill-postal-address: %%UNAME%%
 %%UADDR%%
 requester-group: %%BOR_STATUS%%
 ill-service-type: COPY
 item-id:
 item-type: SERIAL
 item-call-number: %%SIGNATUR%%
 item-title: %%JTITLE%%
 item-author-of-article: %%AUT%%
 item-title-of-article: %%ATITLE%%
 item-pagination: %%PAGES%%
 item-verification-reference-source: %%AUFTRAG%%
 item-volume-issue: %%COMMENT%%
 supplemental-item-description: %%DESCRIPTION%%
 iwc-lls-medium-number: %%ITEMBARCODE%%

Die folgenden Variablen stammen aus den bibliographischen bwz. adminstrativen
Daten von Aleph:

 AUFTRAG      Auftrags-ID                2798
 BOR_STATUS   Benutzer-Status (z305)     Normal
 COLLECTION   Collectioncode             B400M4
 DESCRIPTION  Exemplarnotiz              
 ITEMBARCODE  Barcode des Exemplars      BM1515964
 JTITLE       Journal Titel              Mitteilungen aus dem Paedagogischen Ausb
 PICKUP       Abholort                   Postversand
 SIGNATUR     Signatur(en)               Hz VI 10
 SUBLIB       Bibliothekscode            B400
 SUBLIB_NAME  Kurzbezeichnung Bibliothek BE StUB
 UADDR        Benutzer-Adresse           Gempenstrasse 140
                                         4000 Basel
 UEMAIL       Benutzer-Email             h.muster@myhost.ch
 UID          Benutzer-ID                B123456
 UNAME        Benutzer-Name              Muster Hans

In MyBib.conf kann definiert werden, dass fuer bestimmte Lieferbibliotheken
der Signatur ein Suffix angehaengt wird.

Die folgenden Variablen sind Benutzereingaben:

 ATITLE      Aufsatz-Titel              Lernen und Wiederholen
 AUT         Autor                      Jodok Meier
 COMMENT     Band/Jg/Kommentar          Bd. 66 (2002)
 PAGES       Seiten                     1-50
 
Die folgenden Variablen werden vom DOD Daemon gesetzt:

 REQUESTER_EMAIL   Return E-Mail        info@stub.unibe.ch
 REQUESTER_ID      MyBib-Absender-ID    ALEPH Basel Bern
 TIME1             Datum+Uhrzeit        200301291721


=head2 Logfile

Wenn der dod-Daemon neu gestartet wird, wird ein neues Logfile mit
dem Namen B<myBib-YYYY-Mon-DD.log> angelegt. Die Logdatei enthaelt
Informationen ueber Start und Stop des Daemons, diverse Fehlermeldungen
und eine Zeile fuer jede bearbeitete Datei, mit Zeitstempel der
Bearbeitung. 

 + druck-57235844.bssbkdd 2016-04-17 12:43:00
 - druck-57235848.bssbkdd 2016-04-17 12:45:10

Ein '+' vor dem Dateinamen bedeutet: die Bestellung wurde per Mail an 
den MyBib-Server weitergeleitet.

Ein '-' vor dem Dateinamen bedeutet: die Bestellung hatte keinen
gueltigen Abholort fuer eine MyBib-Bestellung. Sie wurde deshalb
umbenannt und als Print-Bestellung behandelt.

Ein '!' vor dem Dateinamen bedeutet: Mail konnte nicht verschickt werden.
 auf ein Problem mit dem Mailversand hin.

=head2 Aleph Konfiguration

Die folgenden Dateien in Aleph sind betroffen:

=over 1

=item tab38

Der Abholort B<WEB> oder B<POST> muss pro Zweigstelle definiert sein.

=item tab41

Die Print ID fuer Photocopy Requests muss mit B<dd> enden (statt mit B<cp>).

=item www_f_lng/item-photo-request-tail

Sofern als Abholort EMAIL angegeben ist, werden per DHTML zusaetzliche
Informationen zum Elektronischen Versand ausgegeben.

=back

=head1 HISTORY

 06.02.2003 - Testversion (als dodd.pl)
 03.03.2003 - diverse Anpassungen fuer STP
 20.03.2003 - Versand mit leerer del-email-address moeglich
 21.03.2003 - zus. Feld item-volume-issue
 14.01.2004 - Bestellungen mit zwei Signaturen werden korrekt bearbeitet;
 14.04.2004 - neuer Mailserver
 02.07.2004 - mehrere Bibliotheken
 10.08.2005 - Aleph V16
 30.11.2006 - kompletter rewrite
 28.07.2010 - mehrere Aleph-Bibliotheken moeglich fuer eine Mybib-Bibliothek
              (Anlass: A130)
 17.09.2010 - hostname and mail_from hardcoded
 20.10.2010 - MyBib host email konfigurierbar
 14.12.2010 - z305_bor_status im Feld requester-group
 20.01.2011 - z302-id in neuem Feld customer-no
 21.01.2011 - z38-note-1 in Feld del-notes; z38-note-2 an z38-note-1 angebunden
 23.02.2012 - Anpassungen fuer zweigstellensensitive Bearbeitung auch von 
    Postversand-Bestellungen / mesi
    -> ALEPH Tabellen: tab_sub_library.lng (weitere virtuelle 
     Codes fuer Abholorte), tab27, tab38
    -> mybib.pl: Selektion auf z38_pickup_location erweitert
    - neue Variable %%PICKUP%%, uebernimmt Wert aus z38-pickup-location
    - in %%Comment%% Spatium zwischen z38-note-1 und z38-note-2
    (concatenierter Wert) eingefuegt
    - Falls Notiz-Felder nur Spatien enthalten, wird das abgefangen
 23.04.2015 - rewrite: alle lokalisierte Information in Konfigurationsdatei
    verschoben; verhindere mehrere Mailadressen im Feld 
    "requester-email-address" / ava
 01.07.2015 - div. Modifikationen auf Wunsch ZHB LU und ZBZ / ava
    z30-barcode > iwc-lls-medium-number: z30-barcode
    z38-filter-collection > responder-address 
    z302-address-0 > client-name 
    z30-description > supplemental-item-description
    COMMENT enthält neu z38-note-1, z38-note-2, z38-additional-info
      (mit Längenbegrenzung) > requester-note, del-notes, item-volume-issue
    Zeichensatz: keine Fehlermeldung mehr wg. "wide character in Print";
      Zeichen, die nicht im Zeichensatz ISO-8859-1 ("Latin 1") vorkommen,
      werden gnadenlos durch '?' ersetzt.
 14.09.2015 - ueberfluessige Blanks auf Zeilen 2ff. der Benutzeradresse
    entfernt. / ava
 01.03.2016 - Bei mehreren Exemplaren wird das erste nicht ausgeliehene 
    Exemplar berücksichtigt, kenntlich am Element 'section-02/loan-exists'
    mit Inhalt 'N' / ava
 18.04.2016 - datestamp im logfile / ava

=head1 AUTHOR

Originalcode und Idee von meta.walser@ethz.ch

Angepasst fuer IDS Basel Bern von Andres von Arx
und Sibylle Meyer

=head1 COPYRIGHT AND LICENSE

Copyright (c) 2016 by University Library Basel, Switzerland

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.9 or,
at your option, any later version of Perl 5 you may have available.

=head1 SEE ALSO

Das Skript verwendet folgende Perl-Module ausserhalb der Standard-Distribution:
Mail::Sender, XML::Simple

Beschreibung des subito-Bestellformulars und der RE<uuml>ckmeldungen fE<uuml>r den Email-Einsatz /
subito-Arbeitsgemeinschaft ; bearbeitet von Traute Braun-Gorgon und Antje Schroeder. -
Version 2.0. - Stand: 25. Juli 2001

Beschreibung der Schnittstelle zum Bestellempfangs-
und Dokumentversendesystems (DOD-System) / subito-Arbeitsgemeinschaft ;
bearbeitet von Traute Braun-Gorgon und Antje Schroeder. -
Version 2.0. - Stand: 6. August 2001

=cut
