package updatedevice;
use strict;
use warnings;
use JSON;
use Data::Dumper;
use FindBin;
use File::Slurp;
use lib $FindBin::Bin;
#local modules
use CFG2JSON::Scrape;
use Netbox::netbox;
use auth;
sub new {
  my $class=shift;
  my $args={ @_ };
  my $dcache={};
  mkdir("cache") unless -d "cache"; #create directory to hold our cache file
  mkdir("logs") unless -d "logs"; #create directory to hold the log output
  open(STDOUT,'>logs/'.$args->{hostname}.'.log') or die $!;
  if(-f 'cache/'.$args->{hostname}.'.json'){
    my $dcachejson=read_file('cache/'.$args->{hostname}.'.json');
    $dcache=decode_json $dcachejson;
  }
  my $creds=auth->new($args->{client});
  my $d=CFG2JSON::Scrape->new(filepath=>$args->{rancidpath},sitename=>$args->{sitename},hostname=>$args->{hostname});
  my $device=$d->{device};
  print Dumper $device;
  my $nb=netbox->new(token=>$creds->{token},host=>$creds->{host},device=>$device,dcache=>$dcache,debug=>1);
  #my $nb=netbox->new(token=>$creds->{token},host=>$creds->{host},device=>$device,dcache=>$dcache);
  #start by looking for the device in netbox;
  my $devret=$nb->updateDevice();
  if ($nb->{error}){
    print "ERRORS FOUND!\n";
    print Dumper $nb->{error}
  }else{
    open(FILE,">cache/".$args->{hostname}.'.json') or die $!;
    print FILE $d->json();
    print "json file updated!\n";
  }
  return bless { (dev=>$d,nb=>$nb) },$class;


}

1;
