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
  my $cachefile=$cachedir.$args->{device}{hostname}.'.json';
  my $logfile=$logdir.$args->{device}{hostname}.'.log';
  make_path($cachedir) unless -d $cachedir; #create directory to hold our cache file
  make_path($logdir) unless -d $logdir; #create directory to hold the log output
  open(STDOUT,">$logfile") or die $! if !$args->{debug};
  if(-f $cachefile){
    my $dcachejson=read_file($cachefile);
    $dcache=decode_json $dcachejson;
  }
  my $creds=auth->new($args->{client});
  my $nb=PerlNetbox::netbox->new(
  token=>$creds->{token},
  host=>$creds->{host},
  device=>$args->{device},
  dcache=>$dcache,
  debug=>$args->{debug}
  );

  $nb->updateDevice();
  if(!$nb->{error}{critical} && $nb->{device}{interfaces}){
    $nb->updateInterfaces();
    $nb->updateNats() if $args->{device}{nats};
    $nb->updateConnections();
    $nb->updateARP();
  }

  $nb->updatePrimaryIP() if !$nb->{primary_ip} && $nb->{device}{vendor} ne 'opengear';

  if ($nb->{error}{critical}){
    print "CRITICAL ERRORS FOUND NO CACHE CREATED!\n";
    print Dumper $nb->{error};
  }else{
    open(FILE,">$cachefile") or die $!;
    print FILE encode_json $args->{device};
    close FILE;
    print Dumper $nb->{error}{warning};
    #print "json file updated!\n";
  }
  print('> Full Device updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
  return bless { (dev=>$args->{device},nb=>$nb) },$class;
}

1;
