#!/usr/bin/perl

# SpeiBi_Counter.pl
#
# usage:
#   require SpeiBi_Counter.pl
#   $numerus_currens = SpeiBi_Counter();
#
# description:
#   Einfacher textbasierter Zaehler. Liest die aktuelle Zahl aus einer
#   Textdatei, erhoeht die Zahl um eins und speichert die neue Zahl ab.
#   Setzt danach einen Schreibschutz auf die Textdatei. Die Funktion
#   liefert die erhoehte Zahl zurueck.
#
# note:
#   Diese Funktion ist in eine eigenes Skript ausgegliedert, damit Sie
#   sie leichter durch eine eigene, performantere Funktion ersetzen 
#   können: Counter-Webservice oder Counter-Datanbank o.ä.
#        
# history
#   23.02.2015 Andres von Arx
#

use strict;
use FindBin;

sub SpeiBi_Counter() {
    local *F, $_;
    my $DataFile = $FindBin::Bin .'/SpeiBi_Counter.data';
    if ( !-f $DataFile ) {
        open(F,">$DataFile") or die "$0: cannot write $DataFile: $!";
        print F "0";
        close F;
    }
    open(F, "<$DataFile") or die "$0: cannot read $DataFile: $!";
    $_ = <F>;
    chomp;
    close F;
    my $cnt = int($_);
    chmod 0644, $DataFile or die "$0: cannot remove write protection from $DataFile: $!";
    open(F, ">$DataFile") or die "$0: cannot write $DataFile: $!";
    print F ++$cnt;
    close F;
    chmod 0444, $DataFile or die "$0: cannot set write protection to $DataFile: $!";
    return $cnt;
}

1;
