#!/usr/bin/perl

use strict;
use File::Basename;
use File::Copy;

my $PRINTDIR    = '/exlibris/aleph/u22_1/dsv51/print';
my $CHUNKSIZE   = 500;

sub usage {
    print STDERR <<EOD;

Gebrauch:  perl chunk-printfiles.pl

Dieses Programm splittet grosse Aleph Outputdateien in kleinere
Dateien auf. Damit koennen Probleme mit Htmlprint vermieden werden,
z.B. nach einem langen Feiertagswochenende.

Dazu muss *vor* dem Wochenende die SplitMail.conf geaendert werden,
damit die Outputdateien fuer Print und Email zusaetzlich die Datei-
endung ".wait" erhalten.
   # /exlibris/aleph/u22_1/dsv51/dod/bin/SplitMail.conf
   alt: a100nop    a100e       a100p
   neu: a100nop    a100e.wait  a100p.wait

Der dodd Daemon sollte dann neu gestartet werden mit
   /exlibris/aleph/u22_1/dsv51/dod/bin/dodd restart

*Nach* dem Wochenende wird dann dieses Skript aufgerufen. Es liest
Aleph Outputdateien im Verzeichnis $PRINTDIR
mit einer Dateiendung ".wait" und splittet sie in einzelne Teildateien
mit maximal $CHUNKSIZE Druck- bzw. Mailformularen pro Datei. Diese "Chunks"
erhalten die Dateiendung ".chunk".

Die Chunks muessen dann einzeln zum Drucken bzw. Mailen bereitgestellt
werden, indem man von Hand die Dateiendung ".chunk" loescht.

5.02.2013/ava

EOD
    exit;
}

( @ARGV ) and usage;

opendir(DIR, $PRINTDIR)
    or die("$0: cannot readdir $PRINTDIR: $!");
my @files = grep { /\.wait$/ } readdir DIR;
closedir DIR;

foreach my $file ( @files ) {
    my $infile = $PRINTDIR .'/' .$file;
    my $total_records = `grep -c '^## - XML_XSL' $infile`;
    chomp $total_records;
    if ( $total_records > $CHUNKSIZE ) {
        # Datei wird gesplittet
        my $nRec = 0;
        my $nFile = 0;
        my $tmp = '';
        open(IN,"<$infile")
            or die("cannot read $infile: $!");
        while ( <IN> ) {
            if ( /^## - XML_XSL/ ) {
                $nRec++;
            }
            if ( $nRec > $CHUNKSIZE ) {
                if ( $tmp ) {
                    print_chunk($infile,++$nFile,\$tmp);
                }
                $nRec=1;
                $tmp='';
            }
            $tmp .= $_;
        }
        close IN;
        print_chunk($infile,++$nFile,\$tmp);
    } else {
        # Datei muss nicht gesplittet werden
        my $outfile = $infile;
        $outfile =~ s/wait$/chunk/;
        if ( -f $outfile ) {
            warn("WARN: " .basename($outfile) ." exists. Skipping...\n");
            next;
        } else {
            copy($infile, $outfile);
            print basename($outfile), "\n";
        }
    }
}

sub print_chunk {
    my($infile,$nFile,$ref)=@_;
    my $outfile = $infile;
    $outfile =~ s/\.(\w+)\.wait$/_$nFile.$1.chunk/;
    if ( -f $outfile ) {
        warn("WARN: " .basename($outfile) ." exists. Skipping...\n");
        return;
    }
    open(OUT,">$outfile")
        or die("cannot write $outfile: $!");
    print basename($outfile), "\n";
    print OUT $$ref;
    close OUT;
}
