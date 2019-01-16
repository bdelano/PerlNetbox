package PerlNetbox::updatedevice;
use strict;
use warnings;
use JSON;
use Time::HiRes qw(usleep ualarm gettimeofday tv_interval);
use Data::Dumper;
use FindBin;
use File::Slurp;
use File::Path qw(make_path remove_tree);
use lib $FindBin::Bin;
#local modules
use CFG2JSON::Scrape;
use PerlNetbox::netbox;
use auth;
sub new {
  my $t0 = [gettimeofday];
  my $class=shift;
  my $args={ @_ };
  my $dcache={};
  my ($cachedir,$logdir);
  if($args->{path}){
    $cachedir=$args->{path}.'/cache/';
    $logdir=$args->{path}.'/logs/';
  }else{
    $cachedir=$ENV{'HOME'}.'/netbox/cache/';
    $logdir=$ENV{'HOME'}.'/netbox/logs/';
  }
  my $cachefile=$cachedir.$args->{hostname}.'.json';
  my $logfile=$logdir.$args->{hostname}.'.log';
  make_path($cachedir) unless -d $cachedir; #create directory to hold our cache file
  make_path($logdir) unless -d $logdir; #create directory to hold the log output
  open(STDOUT,">$logfile") or die $! if !$args->{debug};
  if(-f $cachefile){
    my $dcachejson=read_file($cachefile);
    $dcache=decode_json $dcachejson;
  }
  my $creds=auth->new($args->{client});
  my $d=CFG2JSON::Scrape->new(
  filepath=>$args->{rancidpath},
  sitename=>$args->{sitename},
  hostname=>$args->{hostname}
  );
  my $nb=PerlNetbox::netbox->new(
  token=>$creds->{token},
  host=>$creds->{host},
  device=>$d->{device},
  dcache=>$dcache,
  altinfo=>$args->{altinfo},
  debug=>$args->{debug}
  );

  $nb->updateDevice();
  if(!$nb->{error}{critical}){
    $nb->updateInterfaces();
    $nb->updateNats() if $d->{device}{nats};
    $nb->updateConnections();
    $nb->updateARP();
  }


  if ($nb->{error}{critical}){
    print "ERRORS FOUND!\n";
    print Dumper $nb->{error};
  }else{
    print Dumper $nb->{error}{warning} if $nb->{error}{warning};
    open(FILE,">$cachefile") or die $!;
    print FILE $d->json();
    #print "json file updated!\n";
  }
  print('> Full Device updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
  return bless { (dev=>$d,nb=>$nb) },$class;
}

1;
