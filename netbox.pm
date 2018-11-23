package netbox;
use strict;
use warnings;
use Time::HiRes qw(usleep ualarm gettimeofday tv_interval);
use IPC::Cmd qw[can_run run run_forked];
use JSON::PP;
use NetAddr::IP;
use Data::Dumper;
use URI::Encode qw(uri_encode uri_decode);
sub new{
  my $class=shift;
  my $self = { @_ };
  $self->{ffdict}=buildffdict();
  $self->{error}=();
  if ($self->{host} && $self->{token}){
    return bless $self,$class;
  }else{
    print "ERROR: Please specify a host and token";
    exit;
  }
}

sub info{
  my $self = shift;
  print $_[0]."\n" if $self->{debug}
}

sub goNetbox{
  my ($self,$path,$id,$p)=@_;
  my $payload='';
  my $rtype='GET';
  if($id){
    $rtype='PATCH';
    $path.=$id.'/';
    if($p eq 'delete'){
      $rtype='DELETE'
    }else{
      $payload=encode_json($p);
    }
  }elsif($p){
    $rtype='POST';
    $payload=encode_json($p);
  }
  my $url='https://'.$self->{host}.'/api/'.uri_encode($path);
  $self->info($url);
  my $cmd='/usr/bin/curl -s -k -X '.$rtype;
  $cmd.=" '$url'";
  $cmd.=" -d '".$payload."'";
  $cmd.=' -H "Content-Type: application/json"';
  $cmd.=' -H "accept: application/json" -H "Authorization: Token '.$self->{token}.'"';
  my $buffer;
  $self->info($cmd);
  scalar run( command => $cmd,verbose => 0, buffer  => \$buffer, timeout => 20 );
  if($rtype eq 'DELETE' && !$buffer){
    my $json_out->{delete}=$path;
    return $json_out;
  }else{
    my $json_out = eval { decode_json($buffer) };
    if($@){
      my $error->{detail}="ERROR: failed to decode JSON: $path : $@";
      return $error;
    }else{
      return $json_out;
    }
  }
}

sub getID{
  my ($self,$p)=@_;
  my $res=$self->goNetbox($p);
  if($res->{error}){
    return "ERROR : getID :  ".$p.":".$res->{error}."\n";
  }else{
    if($res->{results}){
      my $rc=@{$res->{results}};
      if($rc==1){
        return $res->{results}[0]{id};
      }elsif($rc<1){
        return 0;
      }
    }else{
      return "ERROR : getID : results for $p\n";
    }
  }
}

sub getDeviceType{
  my $self = shift;
  my $dtid=$self->getID('dcim/device-types/?model='.$self->{device}{model});
  if($dtid){
    return $dtid;
  }else{
    return '';
    push(@{$self->{error}},'ERROR:unable to find model name'.$self->{device}{model});
  }
}

sub getPlatform{
  my $self = shift;
  my $vendor=$self->{device}{vendor};
  print "vendor:$vendor\n";
  my $platobj={"arista"=>"arista-eos","cisco"=>"cisco-ios","force10"=>"dell-ftos","juniper"=>"juniper-junos"};
  if($platobj->{$vendor}){
    my $id=$self->getID('dcim/platforms/?slug='.$platobj->{$vendor});
    if($id){
      return $id;
    }else{
      push(@{$self->{error}},'ERROR:unable to find platform type:'.$vendor);
    }
  }else{
    push(@{$self->{error}},'error: unable to match $vendor with platform:'.$vendor);
  }

}

sub getDeviceRole{
  my $self = shift;
  my $id=$self->getID('dcim/device-roles/?name='.$self->{device}{devicerole});
  if($id){
    return $id;
  }else{
    push(@{$self->{error}},'ERROR:unable to find device role:'.$self->{device}{devicerole});
  }
}


sub updateDevice{
  my $self = shift;
  my $t0 = [gettimeofday];
  my $devid=$self->getID('dcim/devices/?serial='.$self->{device}{serial});
  my $payload;
  if(!$devid){
    my $geninfo=$self->goNetbox('dcim/sites/?q='.$self->{device}{sitename})->{results}[0];
    if(!$geninfo){
      push(@{$self->{error}},'ERROR: unable to information for site:'.$self->{device}{sitename});
      return;
    }else{
      $payload->{name}=$self->{device}{hostname};
      $payload->{device_type}=$self->getDeviceType();
      $payload->{device_role}=$self->getDeviceRole();
      $payload->{tenant}=$geninfo->{tenant}{id};
      $payload->{serial}=$self->{device}{serial};
      $payload->{platform}=$self->getPlatform();
      $payload->{site}=$geninfo->{id};
    }
  }else{
    $payload->{name}=$self->{device}{hostname}
  }
  $self->info('updating device...');
  my $devret=$self->goNetbox('dcim/devices/',$devid,$payload);
  if($devret->{id}){
    $self->info('found id!');
    $self->{device}->{id}=$devret->{id};
    $self->updateInterfaces();
  }else{
    push(@{$self->{error}},'ERROR: unable to update device:'.$self->{device}{hostname});
  }
  print 'Device updated in '.sprintf("%.2fs\n", tv_interval ($t0))."\n";
}

sub updateInterfaces{
  my $self = shift;
  $self->info('updating interfaces...');
  my $t0 = [gettimeofday];
  my $geninfo=$self->goNetbox('dcim/sites/?q='.$self->{device}{sitename})->{results}[0];
  $self->{device}{siteid}=$geninfo->{id};
  $self->{device}{siteslug}=$geninfo->{slug};
  $self->{device}{tenantid}=$geninfo->{tenant}{id};
  my $devints=$self->{device}{interfaces};
  my $nbxints=$self->{dcache}{interfaces};
  my @intupdate;
  my @retints;
  my @lags;
  for my $int (keys %{$devints}){
    #$self->info('int:'.$int);
    my ($devdescr,$nbxdescr,$devip,$nbxip)=('','','','');
    $devdescr=$devints->{$int}{description} if $devints->{$int}{description};
    $nbxdescr=$nbxints->{$int}{description} if $nbxints->{$int}{description};
    if($devdescr ne $nbxdescr || !$nbxints->{$int}{formfactor}){
      push(@intupdate,$int)
    }
  }

  for my $int (keys %{$nbxints}){
    if(!$devints->{$int}){
      $self->{device}{interfaces}{$int}{delete}='1';
      push (@intupdate,$int);
    }
  }
  if(@intupdate<1){
    print("=> Netbox Interfaces no changes found: ".$self->{device}{hostname}."\n");
  }else{
    print("=> Netbox Interfaces updating interfaces: ".$self->{device}{hostname}."\n");
    #add,delete or update interfaces
    for my $int (@intupdate){
      my $intret=$self->updateInt($int);
      push(@retints,$intret);
    }
    $self->updateLAG();
  }

  print('Interfaces updated in '.sprintf("%.2fs\n", tv_interval ($t0))."\n");
  #return \@retints;
}

sub updateLAG{
  my $self = shift;
  for(@{$self->{device}{lags}}){
    my $i=$self->{device}{interfaces}{$_};
    print Dumper $i;
    #$self->info("parent:".$i->{parent});
    my $payload->{lag}=$self->{device}{interfaces}{$i->{parent}}{id};
    #$self->info("intid:".$i->{id});
    my $ret=$self->goNetbox('dcim/interfaces/',$i->{id},$payload);
    print Dumper $ret;
  }
}
sub updateInt{
  my ($self,$int)=@_;
  my $intid=$self->getID('dcim/interfaces/?device_id='.$self->{device}{id}.'&name='.$int);
  my $i=$self->{device}{interfaces}{$int};
  $self->info('working on:'.$int);
  if(!$i->{formfactor}){
    push(@{$self->{error}},'ERROR: no matching ff was found:'.$self->{device}{hostname}.' '.$int);
    return;
  }
  $self->info('ff:'.uc($i->{formfactor}));
  my $ffid=$self->{ffdict}{uc($i->{formfactor})};
  my $payload->{device}=$self->{device}{id};
  $payload->{name}=$int;
  $payload->{enable}='true';
  $payload->{form_factor}=$ffid;
  $payload->{mtu}=$i->{mtu} if $i->{mtu};
  $payload->{description}=$i->{description} if $i->{description};
  $payload->{mode}=200; #Tagged All 300,Access 100
  $payload->{tags}=[];
  if ($i->{parent}){
    $self->info('FOUND PARENT:'.$i->{parent});
    push(@{$self->{device}{lags}},$int) if $i->{parent};
  }
  #tell netbox to delete interface if this option is set
  $payload='delete' if $i->{delete};
  my $intret=$self->goNetbox('dcim/interfaces/',$intid,$payload);
  if($intret->{id}){
    $self->info('found ID updating ip if necessary!');
    $self->{device}{interfaces}{$int}{id}=$intret->{id};
    $self->{device}{interfaces}{$int}{vrfid}=$self->getVRFid($int);
    $self->updateIPs($int);
  }else{
    push(@{$self->{error}},'ERROR: pushing interface update:'.$self->{device}{hostname}.' '.$int.' '.uc($i->{formfactor}));
  }
}

sub getPrefix{
  my ($self,$int,$ip) = @_;
  my $ninet = new NetAddr::IP $ip->{ip}.'/'.$ip->{bits};
  if($ninet->masklen()<32){
    my $net=$ninet->network.'t';
    $net=~s/t//;
    my $ret=$self->goNetbox('ipam/prefixes/?q='.$net.'&site='.$self->{device}{siteslug});
    if($ret->{count}<1){
      my $payload->{prefix}=$net;
      $payload->{site}=$self->{device}{siteid};
      $payload->{vrf}=$self->{device}{interfaces}{$int}{vrfid};
      $payload->{tenant}=$self->{device}{tenantid};
      $payload->{vlan}=$self->{device}{interfaces}{$int}{vlan};
      $payload->{description}='isprefix';
      $payload->{is_pool}='true';
      $ret=$self->goNetbox('ipam/prefixes/','',$payload);
      return $ret;
    }else{
      return $ret->{results}[0];
    }
  }
}

sub getVRFid{
  my ($self,$int)=@_;
  my $vrf=$self->{device}{interfaces}{$int}{vrf};
  my ($vrfname,$payload);
  if(!$vrf){
    $vrfname='global';
  }else{
    $vrfname=$self->{device}{siteslug}.' '.$vrf;
    my $rd=$vrf.':'.$self->{device}{siteslug};
    $payload->{name}=$vrfname;
    $payload->{rd}=$rd;
    $payload->{tenant}=$self->{device}{tenantid};
    $payload->{enforce_unique}='true';
  }
  my $ret=$self->goNetbox('ipam/vrfs/?q='.$vrfname);
  if($ret->{count}<1){
    $ret=$self->goNetbox('ipam/vrfs/','',$payload);
    return $ret->{id};
  }else{
    return $ret->{results}[0]{id};
  }
}
sub updateIPs{
  my ($self,$int)=@_;
  my $i=$self->{device}{interfaces}{$int};
  my $c=0;
  if($i->{ipaddress}){
    for(@{$i->{ipaddress}}){
      my $ipret=$self->updateIP($int,$_);
      if(!$ipret->{id}){
        push(@{$self->{error}},'ERROR: unable to update ip:'.$self->{device}{hostname}.' '.$int.' '.$_->{ip});
      }
    }
  }
}

sub updateIP{
  my ($self,$int,$ip)=@_;
  my $ipbits=$ip->{ip}.'/'.$ip->{bits};
  $self->info("updating:".$int.' '.$ipbits);
  my $i=$self->{device}{interfaces}{$int};
  my $pfinfo=$self->getPrefix($int,$ip);
  if($i->{vrfid}){
    my $payload->{address}=$ipbits;;
    $payload->{vrf}=$i->{vrfid};
    $payload->{tenant}=$self->{device}{tenantid};
    $payload->{status}=1;
    $payload->{role}=41 if $ip->{type} eq 'vrrp';
    $payload->{description}=$i->{description} if $i->{description};
    $payload->{interface}=$i->{id};
    my $ipq='address='.$ipbits;
    $ipq.='&vrf_id='.$i->{vrfid};
    $payload='delete' if $i->{delete};
    my $ipid=$self->getID('ipam/ip-addresses/?'.$ipq);
    my $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
    if($ipret->{delete}){
      $ipret->{hostname}=$int->{hostname};
      $ipret->{int}=$int->{int};
      $ipret->{ip}=$ipbits;
    }
    return $ipret;
  }else{
    push(@{$self->{error}},'ERROR: unable to build prefix:'.$ipbits.' '.$int.' '.$_->{ip});
  }

}

sub buildffdict{
  my %ffdict;
  $ffdict{'SFP1000BASE-LX'}=1100;
  $ffdict{'SFP1000BASE-SX'}=1100;
  $ffdict{'SFP1000BASE-T'}=1100;
  $ffdict{'1000BASESX SFP'}=1100;
  $ffdict{'SFP1G-LX10'}=1100;
  $ffdict{'SFP-1G-SX'}=1100;
  $ffdict{'XFP10GBASE-LR'}=1300;
  $ffdict{'XFP10GBASE-SR'}=1300;
  $ffdict{'XFP10GBASE-ZR'}=1300;
  $ffdict{'CAB-S-S-25G-1M'}=1350;
  $ffdict{'QSFP40GBASE-CR4'}=1400;
  $ffdict{'QSFP40GBASE-CR4-0.5M'}=1400;
  $ffdict{'QSFP40GBASE-CR4-1M'}=1400;
  $ffdict{'QSFP40GBASE-SR4'}=1400;
  $ffdict{'QSFP40GBASE-SR4(EXT)'}=1400;
  $ffdict{'QSFP+40G-LR4'}=1400;
  $ffdict{'QSFP+40G-SR4'}=1400;
  $ffdict{'QSFP+-40G-SR4'}=1400;
  $ffdict{'QSFP+-40G-LR4'}=1400;
  $ffdict{'QSFP40GBASE-SR4'}=1400;
  $ffdict{'QSFP40GBASE-LR4'}=1400;
  $ffdict{'QSFP28100GBASE-LR4'}=1600;
  $ffdict{'QSFP28100GBASE-LR4-LITE'}=1600;
  $ffdict{'QSFP28100GBASE-SR4'}=1600;
  $ffdict{'QSFP-100G-SR4'}=1600;
  $ffdict{'SFP+10G-ER'}=1200;
  $ffdict{'SFP+10G-LR'}=1200;
  $ffdict{'SFP+10G-SR'}=1200;
  $ffdict{'SFP-10G-SR'}=1200;
  $ffdict{'CAB-SFP-SFP-3M'}=1200;
  $ffdict{'CAB-SFP-SFP-2.5M'}=1200;
  $ffdict{'CAB-SFP-SFP-1.5M'}=1200;
  $ffdict{'CAB-SFP-SFP-2M'}=1200;
  $ffdict{'SFP+10GBASE-CU1M'}=1200;
  $ffdict{'SFP+10GBASE-CU2M'}=1200;
  $ffdict{'SFP+10GBASE-CU3M'}=1200;
  $ffdict{'SFP+10GBASE-CU5M'}=1200;
  $ffdict{'SFP+10GBASE-ER'}=1200;
  $ffdict{'SFP+10GBASE-LR'}=1200;
  $ffdict{'SFP+10GBASE-SR'}=1200;
  $ffdict{'SFP+-10G-ER'}=1200;
  $ffdict{'SFP+-10G-SR'}=1200;
  $ffdict{'SFP+-10G-LR'}=1200;
  $ffdict{'DUAL-SFP+-SR/SFP-SX'}=1200;
  $ffdict{'10/100/1000BASETX'}=1000;
  $ffdict{'100BASE-TX'}=800;
  $ffdict{'VIRTUAL'}=0;
  $ffdict{'LAG'}=200;
  $ffdict{'PHYSICAL'}=32767;
  $ffdict{'NONE'}=32767;
  $ffdict{'UNKNOWN'}=32767;
  return \%ffdict;
}

1;
