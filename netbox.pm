package PerlNetbox::netbox;
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
  $self->{error}{critical}=();
  $self->{error}{warning}=();
  if($self->{altinfo}){
    for(keys %{$self->{altinfo}}){
      my $i=$_;
      my $info=$self->{altinfo}{$i};
      if($self->{device}{interfaces}{$i}){
        $self->{device}{interfaces}{$i}{arp}=$info->{arp} if $info->{arp};
        $self->{device}{interfaces}{$i}{lldp}=$info->{lldp} if $info->{lldp};
        $self->{device}{interfaces}{$i}{macs}=$info->{macs} if $info->{macs};
      }else{
        push(@{$self->{error}{warning}},"ERROR:alt interface $i not found!");
      }
    }
  }

  if ($self->{host} && $self->{token}){
    return bless $self,$class;
  }else{
    print "ERROR: Please specify a host and token";
    exit;
  }
}

sub info{
  my $self = shift;
  print $_[0]."\n" if $self->{debug};
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
    push(@{$self->{error}},$res->{error});
    return;
  }else{
    if($res->{results}){
      my $rc=@{$res->{results}};
      if($rc>=1){
        return $res->{results}[0]{id};
      }elsif($rc<1){
        return 0;
      }
    }else{
      push(@{$self->{error}{warning}},"ERROR : getID : results for $p");
      return;
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
    push(@{$self->{error}{warning}},'ERROR:unable to find model name'.$self->{device}{model});
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
      push(@{$self->{error}{warning}},'ERROR:unable to find platform type:'.$vendor);
    }
  }else{
    push(@{$self->{error}{warning}},'error: unable to match $vendor with platform:'.$vendor);
  }

}

sub getDeviceRole{
  my $self = shift;
  my $id=$self->getID('dcim/device-roles/?name='.$self->{device}{devicerole});
  if($id){
    return $id;
  }else{
    push(@{$self->{error}{warning}},'ERROR:unable to find device role:'.$self->{device}{devicerole});
  }
}


sub updateDevice{
  my $self = shift;
  my $t0 = [gettimeofday];
  if(!$self->{device}{serial}){
    push(@{$self->{error}{critical}},'ERROR:no serialnum found for '.$self->{device}{hostname});
    return;
  }
  my $devid=$self->getID('dcim/devices/?serial='.$self->{device}{serial});
  $devid=$self->getID('dcim/devices/?q='.$self->{device}{hostname}) if !$devid;
  my $payload;
  if(!$devid){
    my $geninfo=$self->goNetbox('dcim/sites/?q='.$self->{device}{sitename})->{results}[0];
    if(!$geninfo){
      push(@{$self->{error}{critical}},'ERROR: unable to information for site:'.$self->{device}{sitename});
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
    $payload->{name}=$self->{device}{hostname};
    $payload->{serial}=$self->{device}{serial};
  }
  $self->info('=> updating device...');
  my $devret=$self->goNetbox('dcim/devices/',$devid,$payload);
  if($devret->{id}){
    #print Dumper $devret;
    $self->info('found id!');
    $self->{device}->{id}=$devret->{id};
    $self->{device}{siteid}=$devret->{site}{id};
    $self->{device}{siteslug}=$devret->{site}{slug};
    $self->{device}{tenantid}=$devret->{tenant}{id};
  }else{
    push(@{$self->{error}{critical}},'ERROR: unable to update device:'.$self->{device}{hostname});
  }
  print('=> Device updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub updateInterfaces{
  my $self = shift;
  $self->info('=> updating interfaces...');
  my $t0 = [gettimeofday];
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
      #print "adding:".$int.':'.$devints->{$int}{formfactor}."\n";
      push(@intupdate,$int)
    }
  }
  for my $int (keys %{$nbxints}){
    if(!$devints->{$int}){
      $self->{device}{interfaces}{$int}{delete}='1';
      push (@intupdate,$int);
    }
  }
  #print Dumper @intupdate;
  if(@intupdate<1){
    print("=> Netbox Interfaces no changes found: ".$self->{device}{hostname}."\n");
  }else{
    print("=> Netbox Interfaces updating interfaces: ".$self->{device}{hostname}."\n");
    #$self->getdevvlans();
    $self->getnbvlans();
    #add,delete or update interfaces
    for my $int (@intupdate){
      my $intret=$self->updateInt($int);
      push(@retints,$intret);
    }
    $self->updateLAG();
    print('=> Interfaces updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
  }
}


sub getnbvlans{
  my $self = shift;
  my $vlaninfo=$self->goNetbox('ipam/vlans/?limit=10000&site_id='.$self->{device}{siteid});
  my %holdhash;
  my @holdarr;
  for(@{$vlaninfo->{results}}){
    my $vl=$_->{vid};
    my $vlid=$_->{id};
    if($self->{nbvlanhash}{$vl}){
      my $cvlid=$self->{nbvlanhash}{$vl};
      if($vlid<$cvlid){
        $self->{nbvlanhash}{$vl}=$vlid
      }
    }else{
      $self->{nbvlanhash}{$vl}=$vlid;
    }
  }
}

sub addvlan{
  my ($self,$vl) = @_;
  $self->getnbvlans();
  if(!$self->{nbvlanhash}{$vl}){
    my $payload->{site}=$self->{device}{siteid};
    $payload->{vlan_id}=$vl;
    $payload->{name}="not found";
    $payload->{tenant}=$self->{device}{tenantid};
    my $vlret=$self->goNetbox('ipam/vlans/','',$payload);
    print "VLAN ADDED $vl \n";
    print Dumper $vlret;
    my $vlid=$vlret->{id};
    $self->{nbvlanhash}{$vl}=$vlid;
  }
}

sub updateLAG{
  my $self = shift;
  for(@{$self->{device}{lags}}){
    my $i=$self->{device}{interfaces}{$_};
    #print Dumper $i;
    #$self->info("parent:".$i->{parent});
    my $payload->{lag}=$self->{device}{interfaces}{$i->{parent}}{id};
    #$self->info("intid:".$i->{id});
    my $ret=$self->goNetbox('dcim/interfaces/',$i->{id},$payload);
    #print Dumper $ret;
  }
}

sub updateInt{
  my ($self,$int)=@_;
  my $intid=$self->getID('dcim/interfaces/?device_id='.$self->{device}{id}.'&name='.$int);
  my $i=$self->{device}{interfaces}{$int};
  if(!$intid && $i->{delete}){
    delete $self->{device}{interfaces}{$int};
    return;
  }
  my $intret;
  $self->info('working on:'.$int);
  if($i->{delete}){
    $intret=$self->goNetbox('dcim/interfaces/',$intid,'delete');
    delete $self->{device}{interfaces}{$int};
  }else{
    if(!$i->{formfactor}){
      push(@{$self->{error}{critical}},'ERROR: no matching ff was found:'.$self->{device}{hostname}.' '.$int);
      #print Dumper $i;
      return;
    }
    my $ffid;
    $ffid=$self->{ffdict}{uc($i->{formfactor})} if $i->{formfactor};
    my $payload->{device}=$self->{device}{id};
    $payload->{name}=$int;
    $payload->{enable}='true';
    $payload->{form_factor}=$ffid if $ffid;
    $payload->{mtu}=$i->{mtu} if $i->{mtu};
    #$payload->{tagged_vlans}=$i->{vlans} if $i->{vlans};
    $payload->{description}=$i->{description} if $i->{description};
    $payload->{mode}=200; #Tagged All 300,Access 100
    $payload->{tags}=[];
    if ($i->{parent}){
      $self->info('FOUND PARENT:'.$i->{parent});
      push(@{$self->{device}{lags}},$int) if $i->{parent};
    }
    $intret=$self->goNetbox('dcim/interfaces/',$intid,$payload);
  }

  if($intret->{id}){
    $self->info('found ID updating ip if necessary!');
    $self->{device}{interfaces}{$int}{id}=$intret->{id};
    $self->{device}{interfaces}{$int}{vrfid}=$self->getVRFid($int);
    $self->updateIPs($int);
  }else{
    push(@{$self->{error}{critical}},'ERROR: pushing interface update:'.$self->{device}{hostname}.' '.$int.' '.uc($i->{formfactor}));
  }
}

sub getPrefix{
  my ($self,$int,$ip) = @_;
  my $ninet = new NetAddr::IP $ip->{ip}.'/'.$ip->{bits};
  if($ninet->masklen()<32){
    my ($net,$bits)=split(/\//,$ninet->network);
    my $pfkey=$net.'/'.$bits.$self->{device}{siteslug};
    my $ret;
    if($self->{prefixhash}{$pfkey}){
      $ret=$self->{prefixhash}{$pfkey}
    }else{
      my $pfret=$self->goNetbox('ipam/prefixes/?contains='.$net.'&mask_length='.$bits.'&site='.$self->{device}{siteslug});
      $ret=$pfret->{results}[0];
      my $pfid=$ret->{id};
      #if($pfret->{count}<1){ #re-enable this after everything gets updated
        my ($vlan,$vlanid);
        if($self->{device}{interfaces}{$int}{vlans}){
          $vlan=$self->{device}{interfaces}{$int}{vlans}[0];
          $vlanid=$self->{nbvlanhash}{$vlan};
          $self->addvlan($vlan) if !$vlanid;
          $vlanid=$self->{nbvlanhash}{$vlan};
        }
        my $payload->{prefix}=$net.'/'.$bits;
        $payload->{site}=$self->{device}{siteid};
        $payload->{vrf}=$self->{device}{interfaces}{$int}{vrfid};
        $payload->{tenant}=$self->{device}{tenantid};
        $payload->{vlan}=$vlanid if $vlanid;
        $payload->{description}='isprefix';
        $payload->{is_pool}='true';
        $ret=$self->goNetbox('ipam/prefixes/',$pfid,$payload);
        push(@{$self->{error}{warning}},'ERROR: updating prefix:'.$net) if !$ret->{id};
        #print Dumper $ret;
      #}else{
      #  $ret=$pfret->{results}[0];
      #}
      $self->{prefixhash}{$pfkey}=$ret;
    }
    return $ret;
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
        push(@{$self->{error}{critical}},'ERROR: unable to update ip:'.$self->{device}{hostname}.' '.$int.' '.$_->{ip});
      }
    }
  }
}

sub updateNats{
  my $self = shift;
  #push(@{$self->{error}},'ERROR: this is just a hold');
  $self->info('=> updating NAT IPs...');
  my $t0 = [gettimeofday];
  my $devnats=$self->{device}{nats};
  my $nbxnats=$self->{dcache}{nats};
  my ($dev,$nbx,$natadd);
  for(@{$nbxnats}){
    $nbx->{$_->{local}.$_->{remote}}=$_->{description};
  }
  for(@{$devnats}){
    $dev->{$_->{local}.$_->{remote}}=$_->{description};
    push(@{$natadd},$_);# if !$nbx->{$_->{local}.$_->{remote}};
  }
  for(@{$natadd}){
    my $locid=$self->getID('ipam/ip-addresses/?address='.$_->{local});
    my $remid=$self->getID('ipam/ip-addresses/?address='.$_->{remote});
    $self->goNetbox('ipam/ip-addresses',$locid,{'nat_inside'=>$remid}) if $locid && $remid;
    print "locip: ".$_->{local}." locid:$locid remid:$remid \n";
  }
  print('=> NATs updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
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
    $payload->{interface}=$i->{id} if $i->{id};
    my $ipq='address='.$ipbits;
    $ipq.='&vrf_id='.$i->{vrfid};
    $payload='delete' if $i->{delete};
    my $ipid=$self->getID('ipam/ip-addresses/?'.$ipq);
    my $ipret;
    if($ip->{type} eq 'arp'  && !$ipid){
      delete $payload->{interface};
      $payload->{description}='ARP for '.$self->{device}{hostname}.' '.$int;
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
      push(@{$self->{device}{arpadded}},$ipret->{id});
    }elsif($ip->{type} ne 'arp'){
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
    }

    if($ipret->{delete}){
      $ipret->{hostname}=$self->{device}{hostname};
      $ipret->{int}=$int;
      $ipret->{ip}=$ipbits;
    }
    return $ipret;
  }else{
    push(@{$self->{error}{critical}},'ERROR: unable to build prefix:'.$ipbits.' '.$int.' '.$_->{ip});
  }
}

sub buildconnhash{
  my $self=shift;
  my $cl=$self->goNetbox('dcim/interface-connections/?device='.$self->{device}{hostname});
  if($cl->{'count'}>0){
    for(@{$cl->{results}}){
      my $res=$_;
      my ($bdev,$aint,$bint);
      if($res->{interface_a}{device}{name} eq $self->{device}{hostname}){
        $aint=$res->{interface_a}{name};
        $bdev=$res->{interface_b}{device}{name};
        $bint=$res->{interface_b}{name};
        my $altbdev=_sub($bdev);
        $self->{connhash}{$aint.':'.$bdev.':'.$bint}=$_->{id};
        $self->{connhash}{$aint.':'.$altbdev.':'.$bint}=$_->{id};
      }
    }
  }
}

sub _removeint{
  my ($self,$int)=@_;
  for(keys %{$self->{connhash}}){
    $self->{connhold}{$_}='hold' if $_=~/^$int:/;
  }
}

sub _sub{
  my $n =  shift;
  my $altsub={
    'ap-northeast'=>'ap-ne',
    'ap-southeast'=>'ap-se',
    'eu-central'=>'eu-c',
    'eu-c-'=>'eu-central',
    'ap-ne'=>'ap-northeast',
    'ap-se'=>'ap-southeast'
  };
  my @als=('ap-northeast','ap-southeast','eu-central','ap-ne','ap-se','eu-c-');
  for(@als){
    my $m=$_;
    if($n=~/$m/){
      $n=~s/$m/$altsub->{$m}/i;
      last;
    }
  }
  return $n;
}

sub updateConnections{
  my $self = shift;
  my $t0 = [gettimeofday];
  $self->buildconnhash();
  my $ints=$self->{device}{interfaces};
  for(keys %{$ints}){
    $self->connectMACs($_) if $ints->{$_}{macs};
    $self->connectLLDP($_) if $ints->{$_}{lldp};
  }

  for(keys %{$self->{connhold}}){
    delete $self->{connhash}{$_};
  }
  my $delhold;
  my $ch=$self->{connhash};
  for(keys %{$ch}){
    if(!$delhold->{$ch->{$_}}){
      $delhold->{$ch->{$_}}='deleted';
      print "deleting:".$_."\n";
      #my $del=$self->goNetbox('dcim/interface-connections/',$ch->{$_},'delete');
    }
  }
  print('=> Connections updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub connectLLDP{
  my ($self,$int) = @_;
  my $t0 = [gettimeofday];
  my $connhash=$self->{connhash};
  my $ints=$self->{device}{interfaces};
  for(@{$ints->{$int}{lldp}}){
    my $rh=$_->{rh};
    my $ri=$_->{ri};
    $ri=~s/Gi/GigabitEthernet/ if $ri=~/Gi[\d]/;
    $ri=~s/(.*)/$1.0/ if $ri=~/et-/;
    my $key=$int.':'.$rh.':'.$ri;
    my $altrh=_sub($rh);
    my $altkey=$int.':'.$altrh.':'.$ri;
    $self->_removeint($int);
    if(!$connhash->{$key} && !$connhash->{$altkey}){
      print "no connections found!\n";
      print "key:$key\n";
      print "rkey:$altkey\n";
      my $nbrintid=$self->getID('dcim/interfaces/?device='.$rh.'&name='.$ri);
      if(!$nbrintid){
        my $rdevid=$self->getID('dcim/devices/?q='.$rh);
        $nbrintid=$self->getID('dcim/interfaces/?device_id='.$rdevid.'&name='.$ri);
      }
      if($nbrintid){
        my $nblintid=$ints->{$int}{id};
        $nblintid=$self->getID('dcim/interfaces/?name='.$int.'&device_id='.$self->{device}{id}) if !$nblintid;
        if($nblintid){
          $ints->{$int}{id}=$nblintid;
          my $payload={"interface_a"=>$nblintid,"interface_b"=>$nbrintid};
          my $conninfo=$self->goNetbox('dcim/interface-connections/','',$payload);
        }else{
          push(@{$self->{error}{warning}},"lldp Connect ERROR: no match for $int");
        }
      }else{
        push(@{$self->{error}{warning}},"lldp Connect ERROR: remote interface not found! $rh $ri");
      }
    }
  }
  print('==>'.$int.' LLDP connected in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub connectMACs{
  my ($self,$int) = @_;
  my $t0 = [gettimeofday];
  my $connhash=$self->{connhash};
  my $ints=$self->{device}{interfaces};
  for(@{$ints->{$int}{macs}}){
    my $mac=$_;
    my $nbmacinfo=$self->goNetbox('dcim/interfaces/?mac_address='.$mac)->{results}[0];
    my $nbmacid=$nbmacinfo->{id};
    if($nbmacid){
      my ($rh,$ri)=($nbmacinfo->{device}{name},$nbmacinfo->{name});
      my $key=$int.':'.$rh.':'.$ri;
      my $altrh=_sub($rh);
      my $altkey=$int.':'.$altrh.':'.$ri;
      $self->_removeint($int);
      if(!$connhash->{$key} && !$connhash->{$altkey}){
        my $nbintid=$ints->{$int}{id};
        $nbintid=$self->getID('dcim/interfaces/?name='.$int.'&device_id='.$self->{device}{id}) if !$nbintid;
        if($nbintid){
          $ints->{$int}{id}=$nbintid;
          my $payload={"interface_a"=>$nbintid,"interface_b"=>$nbmacid};
          my $conninfo=$self->goNetbox('dcim/interface-connections/','',$payload);
          #print Dumper $conninfo;
        }else{
          push(@{$self->{error}{warning}},"mac Connect ERROR: no match for $int");
        }
      }
    }else{
      #push(@{$self->{error}},"Connect ERROR: no match for $mac");
    }
  }
  print('==>'.$int.' MACs connected in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub updateARP{
  my $self = shift;
  my $t0 = [gettimeofday];
  $self->currentArp();
  my $ints=$self->{device}{interfaces};
  my $cints=$self->{dcache}{interfaces};

  for(keys %{$ints}){
    my $int=$_;
    if($ints->{$int}{arp}){
      my @addarp;
      if($ints->{$int}{ipaddress}[0]){
        $self->updateBits($int,$ints->{$int}{ipaddress},$ints->{$int}{arp});
      }else{
        for(@{$ints->{$int}{arp}}){
          $self->updateBits($int,$ints->{'Vlan '.$_->{vlan}}{ipaddress},$ints->{$int}{arp}) if $ints->{'Vlan '.$_->{vlan}}{ipaddress}[0];
        }
      }

      for(@{$ints->{$int}{arp}}){
        if($_->{bits}){
          $_->{type}='arp';
          my $ipnet=$_->{ip}.'/'.$_->{bits};
          my $m=$_->{ip};
          delete $self->{currentarp}{$ipnet};
          push(@addarp,$_) if !grep($m,$cints->{$int}{arp});
        }
      }

      if(!$ints->{$int}{id} && @addarp>0){
        my $intid=$self->getID('dcim/interfaces/?device_id='.$self->{device}{id}.'&name='.$int);
        $ints->{$int}{id}=$intid;
        $ints->{$int}{vrfid}=$self->getVRFid($int);
      }

      for(@addarp){
        my $ipnet=$_->{ip}.'/'.$_->{bits};
        if(!$self->{currentarp}{$ipnet} && $_->{bits}){
          $self->updateIP($int,$_);
        }
      }
    }
  }
  for(keys %{$self->{currentarp}}){
    print "deleting:$_\n";
    $self->goNetbox('ipam/ip-addresses/',$self->{currentarp}{$_},'delete');
  }
  print('=> ARP updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub currentArp{
  my $self = shift;
  my $ret=$self->goNetbox('ipam/ip-addresses/?q=ARP for '.$self->{device}{hostname}.'&limit=1000');
  if($ret->{count}>0){
    for(@{$ret->{results}}){
      $self->{currentarp}{$_->{address}}=$_->{id};
    }
  }
}

sub updateBits{
  my ($self,$int,$ips,$arps)=@_;
  my $nets;
  for(@{$ips}){
    if($_->{bits}){
      my $n=new NetAddr::IP $_->{ip}.'/'.$_->{bits};
      push(@{$nets},$n);
    }
  }
  my $c=0;
  for(@{$arps}){
    my $ipi=$_;
    my $nip=new NetAddr::IP $ipi->{ip};
    if(!$ipi->{bits}){
      for(@{$nets}){
        my $n=$_;
        if($n->contains($nip)){
          $arps->[$c]{bits}=$n->masklen();
          last;
        }
      }
      $arps->[$c]{bits}='32' if !$arps->[$c]{bits};
    }
    $c++;
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
  $ffdict{'GLC-T-LU'}=1100;
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
  $ffdict{'Q-4SPC03'}=1400;
  $ffdict{'QSFP28100GBASE-LR4'}=1600;
  $ffdict{'QSFP28100GBASE-LR4-LITE'}=1600;
  $ffdict{'QSFP28100GBASE-SR4'}=1600;
  $ffdict{'QSFP-100G-SR4'}=1600;
  $ffdict{'QSFP-100G-CWDM4'}=1600;
  $ffdict{'QSFP-100G-LR4'}=1600;
  $ffdict{'SFP+10G-ER'}=1200;
  $ffdict{'SFP+10G-LR'}=1200;
  $ffdict{'SFP+10G-SR'}=1200;
  $ffdict{'SFP-10G-SR'}=1200;
  $ffdict{'SFP-10G-LR'}=1200;
  $ffdict{'SFPP30-03'}=1200;
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
  $ffdict{'SFP-10G-LR'}=1200;
  $ffdict{'SFP+-10G-ER'}=1200;
  $ffdict{'SFP+-10G-SR'}=1200;
  $ffdict{'SFP+-10G-LR'}=1200;
  $ffdict{'DUAL-SFP+-SR/SFP-SX'}=1200;
  $ffdict{'10/100/1000BASETX'}=1000;
  $ffdict{'SFP-T'}=1000;
  $ffdict{'SFP-GB-GE-T'}=1000;
  $ffdict{'100BASE-TX'}=800;
  $ffdict{'VIRTUAL'}=0;
  $ffdict{'LAG'}=200;
  $ffdict{'PHYSICAL'}=32767;
  $ffdict{'NONE'}=32767;
  $ffdict{'UNKNOWN'}=32767;
  $ffdict{'CFPX-200G-DWDM'}=32767;
  return \%ffdict;
}

1;
