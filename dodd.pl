# dodd.pl

use strict;
use sigtrap qw(handler exit_handler normal-signals);
use File::Basename ();
use File::Copy ();
use FindBin;
use POSIX qw/strftime/;

my $VERSION     = '6.00';

# --------------------------
# Initialisierung
# --------------------------
my $WantedFiles = {};
my @LogFiles    = ();

require "$FindBin::Bin/dodd.conf";
our($PrintDir,$LogDir,$SleepTime,$ExitTime,@Active_Programs);

foreach my $prog ( @Active_Programs ) {
    require "$FindBin::Bin/$prog";
}

my $LogFile = $LogDir .strftime("/dodd-%Y-%b-%d.log", localtime);
open(MAINLOG, ">>$LogFile") or die("cannot write $LogFile: $!");
my $ofh = select MAINLOG; $| = 1; select $ofh;
print MAINLOG File::Basename::basename($0), " v.$VERSION\n";
print MAINLOG 'daemon started at ', scalar(localtime), "\n";

# --------------------------
# Arbeitsschlaufe
# --------------------------
while ( 1 ) {
    if ( int($ExitTime) and $ExitTime le strftime("%H%M",localtime) ) {
        exit_handler();
    }
    check_requests();
    sleep $SleepTime;
}

sub check_requests {
    local($_,*DIR);
    print MAINLOG strftime("check %H:%M:%S\n", localtime);
    opendir(DIR,"$PrintDir") or die("cannot readdir $PrintDir: $!");
    my @files = grep { -f "$PrintDir/$_" } readdir DIR;
    closedir DIR;

    foreach my $suffix ( keys %$WantedFiles ) {
        my @wanted = grep { ( /$suffix$/ ) && ( $_="$PrintDir/$_" ) } @files;
        if ( @wanted ) {
            my $handler = $WantedFiles->{$suffix};
            &$handler(\@wanted);
        }
    }
}

# --------------------------
# Aufputzarbeiten
# --------------------------
sub exit_handler {
    local *SUBLOG;
    if ( int($ExitTime) and $ExitTime le strftime("%H%M",localtime) ) {
        print MAINLOG "exit time reached.\n";
    } else {
        print MAINLOG "caught terminating signal.\n";
    }
    print MAINLOG "daemon stopped at ", scalar(localtime), "\n\n";
    close MAINLOG;
    foreach my $logfile ( @LogFiles ) {
        if ( open(SUBLOG,">>$logfile") ) {
            print SUBLOG 'daemon stopped at ', scalar(localtime), "\n\n";
            close SUBLOG;
        }
    }
    exit 0;
}

# --------------------------
# utilities
# --------------------------
sub register_suffix {
    my($suffix,$coderef)=@_;
    ( ref($coderef) eq 'CODE' )
        or die ("argument 2 to register_suffix must be a code ref\n");
    $WantedFiles->{$suffix} = $coderef;
}

sub register_logfile {
    local *SUBLOG;
    my $token=shift;
    my $logfile="$LogDir/$token" .strftime("-%Y-%b-%d.log", localtime);
    push(@LogFiles,$logfile);
    open(SUBLOG,">>$logfile") or die("cannot append to logfile $logfile: $!\n");
    my $ofh = select SUBLOG; $| = 1; select $ofh;
    print SUBLOG "$token log\ndaemon started at ", scalar(localtime), "\n";
    close SUBLOG;
    $logfile;
}

sub move_to_savedir {
    my $printfile=shift;
    my $basename=File::Basename::basename($printfile);
    my $savedir = $PrintDir . strftime("/save-%Y-%m-%d", localtime);
    unless ( -d $savedir ) {
        mkdir($savedir, 0775);
    }
    my $savefile = $savedir . '/' . $basename . strftime("-%H-%M-%S", localtime);
    File::Copy::move( $printfile, $savefile );
}

__END__

=head1 NAME

dodd.pl - Document Delivery Daemon for Aleph 500

=head1 SYNOPSIS

Das Shellscript B<dodd> besorgt das Starten, Stoppen und Ueberwachen
des Daemons.

  $ dodd start      # startet den Daemon
  $ dodd stop       # stoppt den Daemon
  $ dodd restart    # stoppt und startet den Daemon
  $ dodd check      # prueft, ob der Daemon laeuft

=head1 DESCRIPTION

Das Programm bindet beim Start mit C<require> verschiedene Unterprogramme
ein. Diese registrieren bestimmte 'Print IDs' (Suffixe von Aleph 500
Printdateien) und einen Handler, der fuer diese Printdateien ausgefuehrt
werden soll.

Das Programm prueft dann periodisch, ob der Aleph Printdaemon ue_06 Dateien
mit einem dieser Suffixe in das Printverzeichnis der ADM library geschrieben
hat. Falls ja, wird der registrierte Handler fuer diese Dateien aufgerufen.

Dem Handler wird beim Aufruf ein ArrayRef uebergeben. Dieser enthaelt
die vollstaendigen Pfade aller Dateien mit dem gewuenschten Suffix.

=over 1

=item register_suffix ( suffix, handler )

Registriert ein Dateisuffix (Scalar oder RegEx) und den Handler (CodeRef),
der fuer jede der Dateien mit dem matchenden Suffix aufgerufen werden soll.

=item register_logfile ( token )

Liefert den Dateinamen 'path_to_logdir/token-YYYY-MM-DD.log' und schreibt
beim Starten und Beenden des Daemons eine Datumszeile in das Log.

=item move_to_savedir ( filepath )

Verschiebt eine Printdatei in das Unterverzeichnis save-YYYY-MM-DD,
so wie das nach dem Ausdruck durch den Aleph Taskmanager geschehen wuerde.
Die Printdatei erhaelt dabei die Extension -hh-mm-ss. Das Unterverzeichnis
wird angelegt, falls es noch nicht existiert.

=back

=head2 Beispiel fE<uuml>r ein Unterprogramm

 # -- Initialisierung
 register_suffix('my_suffix', \&my_handler);
 my $logfile = register_logfile('my_log');

 # -- Handler
 sub my_handler {
    my $filelist = shift;
    local *LOG;
    open(LOG,">>$logfile") or die $!;
    foreach my $file ( @$filelist ) {
        print LOG "doing somethint to $file...\n";
    }
    close LOG;
 }

=head1 HISTORY

 2.00 - 30.11.2006 - rewrite
 2.01 - 28.11.2007 - V18/blu
 3.00 - 29.01.2009 - ChangeHold.pl/ava
 4.00 - 20.09.2011 - NotifyMail.pl/ava
 4.01 - 05.02.2012 - Aleph V.20
 5.00 - 30.03.2013 - V21/blu
 5.01 - 01.04.2013 - changehold.pl auskommentiert 08.02.2013 /mesi
 5.02 - 11.02.2015 - SpeiBi.pl/blu
 6.00 - 29.04.2015 - Lokalisierung nach dodd.conf verschoben, Code geputzt/ava

=head1 AUTHOR

Andres von Arx

=cut

