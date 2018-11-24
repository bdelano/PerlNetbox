package PerlNetbox::updatedevice;
use strict;
use warnings;
use JSON;
use Data::Dumper;
use FindBin;
use File::Slurp;
use lib $FindBin::Bin;
#local modules
use CFG2JSON::Scrape;
use PerlNetbox::netbox;
use auth;
sub new {
  my $class=shift;
  my $args={ @_ };
  my $dcache={};
  my $cachedir=$ENV{'HOME'}.'/pncache/';
  my $logdir=$ENV{'HOME'}.'/pnlogs/';
  my $cachefile=$cachedir.$args->{hostname}.'.json';
  my $logfile=$logdir.$args->{hostname}.'.log';
  mkdir($cachedir) unless -d $cachedir; #create directory to hold our cache file
  mkdir($logdir) unless -d $logdir; #create directory to hold the log output
  open(STDOUT,">$logfile") or die $!;
  if(-f $cachefile){
    my $dcachejson=read_file($cachefile);
    $dcache=decode_json $dcachejson;
  }
  my $creds=auth->new($args->{client});
  my $d=CFG2JSON::Scrape->new(filepath=>$args->{rancidpath},sitename=>$args->{sitename},hostname=>$args->{hostname});
  my $device=$d->{device};
  my $nb=PerlNetbox::netbox->new(token=>$creds->{token},host=>$creds->{host},device=>$device,dcache=>$dcache,debug=>1);
  my $devret=$nb->updateDevice();
  if ($nb->{error}){
    print "ERRORS FOUND!\n";
    print Dumper $nb->{error}
  }else{
    open(FILE,$cachefile) or die $!;
    print FILE $d->json();
    print "json file updated!\n";
  }
  return bless { (dev=>$d,nb=>$nb) },$class;


}

1;
