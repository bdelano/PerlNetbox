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
  $self->info($path);
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
  my $platobj={
    "arista"=>"arista-eos",
    "cisco"=>"cisco-ios",
    "force10"=>"dell-ftos",
    "juniper"=>"juniper-junos",
    "opengear"=>"opengear",
    "APC"=>"apc",
    "Sentry"=>"sentry"
  };
  if($platobj->{$vendor}){
    my $id=$self->getID('dcim/platforms/?slug='.$platobj->{$vendor});
    if($id){
      return $id;
    }else{
      push(@{$self->{error}{warning}},'ERROR:unable to find platform type:'.$vendor);
    }
  }else{
    push(@{$self->{error}{warning}},'error: unable to match vendor with platform:'.$vendor);
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
    $self->{device}{id}=$devret->{id};
    $self->{siteid}=$devret->{site}{id};
    $self->{siteslug}=$devret->{site}{slug};
    $self->{tenantid}=$devret->{tenant}{id};
    $self->{primary_ip}=$devret->{primary_ip4};
  }else{
    push(@{$self->{error}{critical}},'ERROR: unable to update device:'.$self->{device}{hostname});
  }
  print('=> Device updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub updatePrimaryIP{
  my $self=shift;
  $self->info('trying to update primary IP');
  my $ipret=$self->goNetbox('ipam/ip-addresses/?address='.$self->{device}{mgmtip})->{results};
  if(@{$ipret}==1){
    my $payload->{primary_ip4}=$ipret->[0]{id};
    if(!$ipret->[0]{interface}){
      my $intid=$self->addmgmtinterface();
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipret->[0]{id},{interface=>$intid});
    }
    $self->goNetbox('dcim/devices/',$self->{device}{id},$payload);
  }else{
    my $pfret=$self->getHighestPrefix($self->{device}{mgmtip});
    if(@{$ipret}<1){
      if($pfret){
        my $intid=$self->addmgmtinterface();
        my $payload->{address}=$self->{device}{mgmtip}.'/'.$pfret->{bits};
        $payload->{vrf}=$pfret->{vrf};
        $payload->{prefix}=$pfret->{id};
        $payload->{tenant}=$self->{tenantid};
        $payload->{interface}=$intid;
        $ipret=$self->goNetbox('ipam/ip-addresses/','',$payload);
        $self->goNetbox('dcim/devices/',$self->{device}{id},{primary_ip4=>$ipret->{id}});
      }
    }else{
      push(@{$self->{error}{warning}},'ERROR: unable to set mgmt ip '.$self->{device}{hostname});
    }
  }
}

sub addmgmtinterface{
  my $self = shift;
  my $intret=$self->goNetbox('dcim/interfaces/','',{name=>'mgmt',mgmt_only=>'true',device=>$self->{device}{id}});
  return $intret->{id};
}

sub updateInterfaces{
  my $self = shift;
  $self->info('=> updating interfaces...');
  my $t0 = [gettimeofday];
  my $devints=$self->{device}{interfaces};
  my $nbxints=$self->{dcache}{interfaces};
  $self->getcurrentInterfaces() if !$nbxints;
  my @intupdate;
  my @retints;
  my @lags;
  for my $int (keys %{$devints}){
    #$self->info('int:'.$int);
    my ($devdescr,$nbxdescr,$devip,$nbxip)=('','','','');
    $devdescr=$devints->{$int}{description} if $devints->{$int}{description};
    $nbxdescr=$nbxints->{$int}{description} if $nbxints->{$int}{description};
    if($devdescr ne $nbxdescr || !$nbxints->{$int}{formfactor}){
      delete $self->{currentints}{$int};
      #print "adding:".$int.':'.$devints->{$int}{formfactor}."\n";
      push(@intupdate,$int)
    }
  }
  for my $int (keys %{$nbxints}){
    if(!$devints->{$int}){
      print "marking $int for deletion!\n";
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
    #for(keys %{$self->{currentints}}){
    #  my $delret=$self->goNetbox('dcim/interfaces/',$self->{currentints}{$_},'delete');
    #  print Dumper $delret;
    #}
    for my $int (@intupdate){
      my $intret;
      if($self->{device}{vendor} eq 'opengear' || $int eq 'console'){
        my $serv;
        $serv='-server' if $int ne 'console';
        $intret=$self->updateConsole($int,$serv)
      }else{
        $intret=$self->updateInt($int);
      }
      push(@retints,$intret);
    }

    $self->updateLAG();
    print('=> Interfaces updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
  }
}

sub getcurrentInterfaces{
  my $self = shift;
  my $intret;
  if($self->{device}{vendor} eq 'opengear'){
    $intret=$self->goNetbox('dcim/console-server-ports/?limit=1000&device_id='.$self->{device}{id})->{results};
  }else{
    $intret=$self->goNetbox('dcim/interfaces/?limit=1000&device_id='.$self->{device}{id})->{results};
  }
  for(@{$intret}){
    $self->{currentints}{$_->{name}}=$_->{id};
  }
}

sub getnbvlans{
  my $self = shift;
  my $count=1;
  my $limit=100;
  my $i=0;
  while($count>0){
    my $offset=$limit * $i;
    $i++;
    my $vlaninfo=$self->goNetbox('ipam/vlans/?limit='.$limit.'&offset='.$offset.'&site_id='.$self->{siteid});
    $count=scalar(@{$vlaninfo->{results}});
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
}

sub addvlan{
  my ($self,$vl) = @_;
  $self->getnbvlans();
  if(!$self->{nbvlanhash}{$vl}){
    my $payload->{site}=$self->{siteid};
    $payload->{vid}=$vl;
    $payload->{name}="not found";
    $payload->{tenant}=$self->{tenantid};
    my $vlret=$self->goNetbox('ipam/vlans/','',$payload);
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

sub updateConsole{
  my ($self,$int,$server)=@_;
  my $i=$self->{device}{interfaces}{$int};
  my $portname=$int.':'.$i->{label};
  my $intid=$self->getID('dcim/console'.$server.'-ports/?device_id='.$self->{device}{id}.'&name='.$portname);
  if(!$intid && $i->{delete}){
    delete $self->{device}{interfaces}{$int};
    return;
  }
  my $intret;
  if($i->{delete}){
    $intret=$self->goNetbox('dcim/console'.$server.'-ports/',$intid,'delete');
    delete $self->{device}{interfaces}{$int};
  }else{
    my $payload->{device}=$self->{device}{id};
    $payload->{name}=$portname;
    $intret=$self->goNetbox('dcim/console'.$server.'-ports/',$intid,$payload);
    if($intret->{id}){
      if($int ne 'console'){
        my $rmdevret=$self->goNetbox('dcim/devices/?q='.$i->{label})->{results};
        if(@{$rmdevret}==1){
          my $cpid=$self->getID('dcim/console-ports/?name=console&device_id='.$rmdevret->[0]{id});
          my $payload->{cs_port}=$intret->{id};
          $self->goNetbox('dcim/console-ports/',$cpid,$payload);
        }elsif(@{$rmdevret}>1){
          push(@{$self->{error}{warning}},'console:too many device matches'.@{$rmdevret}.' '.$i->{label});
        }else{
          push(@{$self->{error}{warning}},'console:no devices found for '.$i->{label});
        }
      }
    }else{
      push(@{$self->{error}{critical}},'ERROR: pushing console update:'.$self->{device}{hostname}.' '.$int);
    }


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

    my $payload->{device}=$self->{device}{id};
    $payload->{name}=$int;
    $payload->{enable}='true';
    $payload->{form_factor}=$self->{ffdict}{uc($i->{formfactor})};
    $payload->{mtu}=$i->{mtu} if $i->{mtu};
    #$payload->{tagged_vlans}=$i->{vlans} if $i->{vlans};
    my $descr=$i->{description};
    $descr=~s/.*(.{99})$/$1/i if $descr;#cut down to last 99 characters so it will fit
    $payload->{description}=$descr if $descr;
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

sub getHighestPrefix{
  my ($self,$ip) = @_;
  my $pfret=$self->goNetbox('ipam/prefixes/?contains='.$ip.'&site='.$self->{siteslug});
  my $ret;
  for(@{$pfret->{results}}){
    my ($network,$bits)=split('/',$_->{prefix});
    my $obj={pfid=>$_->{id},vrfid=>$_->{vrf}{id},network=>$network,bits=>$bits};
    if($ret){
      print "ret:".$ret->{bits}." bits:$bits \n";
      if($ret->{bits}<$bits){
        $ret=$obj;
      }
    }else{
      $ret=$obj;
    }
  }
  return $ret;
}

sub getPrefix{
  my ($self,$int,$ip) = @_;
  my $ninet = new NetAddr::IP $ip->{ip}.'/'.$ip->{bits};
  if($ninet->masklen()<32){
    my ($net,$bits)=split(/\//,$ninet->network);
    my $pfkey=$net.'/'.$bits.$self->{siteslug};
    my $ret;
    if($self->{prefixhash}{$pfkey}){
      $ret=$self->{prefixhash}{$pfkey}
    }else{
      my $pfret=$self->goNetbox('ipam/prefixes/?contains='.$net.'&mask_length='.$bits.'&site='.$self->{siteslug});
      $ret=$pfret->{results}[0];
      my $pfid=$ret->{id};
      if($pfret->{count}<1){
        my ($vlan,$vlanid);
        if($self->{device}{interfaces}{$int}{vlans}){
          $vlan=$self->{device}{interfaces}{$int}{vlans}[0];
          $vlanid=$self->{nbvlanhash}{$vlan};
          $self->addvlan($vlan) if !$vlanid;
          $vlanid=$self->{nbvlanhash}{$vlan};
        }
        my $payload->{prefix}=$net.'/'.$bits;
        $payload->{site}=$self->{siteid};
        $payload->{vrf}=$self->{device}{interfaces}{$int}{vrfid};
        $payload->{tenant}=$self->{tenantid};
        $payload->{vlan}=$vlanid if $vlanid;
        $payload->{description}='isprefix';
        $payload->{is_pool}='true';
        $ret=$self->goNetbox('ipam/prefixes/',$pfid,$payload);
        push(@{$self->{error}{warning}},'ERROR: updating prefix:'.$net) if !$ret->{id};
        #print Dumper $ret;
      }else{
        $ret=$pfret->{results}[0];
      }
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
    $vrfname=$self->{siteslug}.' '.$vrf;
    my $rd=$vrf.':'.$self->{siteslug};
    $payload->{name}=$vrfname;
    $payload->{rd}=$rd;
    $payload->{tenant}=$self->{tenantid};
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
      my $ipret=$self->updateIP($int,$i,$_);
      if(!$ipret->{id}){
        push(@{$self->{error}{critical}},'ERROR: unable to update ip:'.$self->{device}{hostname}.' '.$int.' '.$_->{ip});
      }
    }
  }
}


sub updateNats{
  my $self = shift;
  #$self->info('=> updating NAT IPs...');
  $self->currentNAT();
  my $t0 = [gettimeofday];
  my $ints=$self->{device}{interfaces};
  my $cints=$self->{dcache}{interfaces};
  my $devnats=$self->{device}{nats};
  my $nbxnats=$self->{dcache}{nats};
  my $natobj;
  for(keys %{$devnats}){
    my $set=$_;
    for(keys %{$devnats->{$set}}){
      my $rule=$_;
      my $rinfo=$devnats->{$set}{$rule};
      my $crinfo=$nbxnats->{$set}{$rule};
      if($rinfo->{type} eq 'pool'){
        my $pn=$rinfo->{then}{pool}{name};
        my $i=0;
        for(@{$rinfo->{then}{pool}{addresses}}){
          my $cai=$crinfo->{then}{pool}{addresses}[$i];
          my $ai=$_;
          if(!$self->{nathold}{$ai->{address}}){
            $self->{nathold}{$ai->{address}}='hold';
            my $description=$self->{device}{hostname}.' pool:'.$pn;
            my ($int,$ipaddr,$bits)=('nat',$ai->{ip},$ai->{bits});
            $int=$ai->{locint}{int} if $ai->{locint};
            $bits=$ai->{locint}{bits} if $ai->{locint};
            delete $self->{currentnat}{"$ipaddr/$bits"};
            my $ip={'ip'=>$ipaddr,'bits'=>$bits,'type'=>'nat'};
            my $no={'type'=>'pool','description'=>$description,'ip'=>$ip};
            push(@{$natobj->{$int}},$no) if !$cai->{address} || $ai->{address} ne $cai->{address}
          }
          $i++;
        }
      }elsif($rinfo->{type} eq 'static'){
        my $l=$rinfo->{match}{destination}[0];
        my $r=$rinfo->{then}{static};
        my $cl=$crinfo->{match}{destination}[0];
        my $cr=$crinfo->{then}{static};
        my $description=$self->{device}{hostname}.' '.$rule.' '.$l->{address}.' to '.$r->{address};
        my ($int,$ipaddr,$bits)=('nat',$l->{ip},$l->{bits});
        $int=$l->{locint}{int} if $l->{locint};
        $bits=$l->{locint}{bits} if $l->{locint};
        delete $self->{currentnat}{"$ipaddr/$bits"};
        my $ip={'ip'=>$ipaddr,'bits'=>$bits,'type'=>'nat'};
        my $remote={'ip'=>$r->{ip},'bits'=>$r->{bits},'type'=>'remote'};
        my $no={'type'=>'static','description'=>$description,'ip'=>$ip,'remote'=>$remote};
        push(@{$natobj->{$int}},$no) if $l->{address} ne $cl->{address} || $r->{address} ne $cr->{address};
      }
    }
  }
  for(keys %{$natobj}){
    my $int=$_;
    if(!$ints->{$int}{id}){
      my $intid = $self->getID('dcim/interfaces/?device_id='.$self->{device}{id}.'&name='.$int);
      $ints->{$int}{id}=$intid;
      $ints->{$int}{vrfid}=$self->getVRFid($int);
    }
    for(@{$natobj->{$int}}){
      my $ipret=$self->updateIP($int,{'description'=>$_->{description},'vrfid'=>$ints->{$int}{vrfid},'id'=>$ints->{$int}{id}},$_->{ip});
      my $locid=$ipret->{id};
      push(@{$self->{error}{warning}},'ERROR: unable to get id for NAT address:'.$_->{ip}{ip}) if !$locid;
      if($_->{type} eq 'static' && $locid){
        my $remid=$self->updateIP($int,{'vrfid'=>$ints->{$int}{vrfid}},$_->{remote});
        $self->goNetbox('ipam/ip-addresses',$locid,{'nat_inside'=>$remid}) if $locid && $remid;
        push(@{$self->{error}{warning}},'ERROR: unable to get id for Remote NAT address:'.$_->{remote}{ip}) if !$remid;
        #my $ipret=$self->updateIP($int,{'description'=>$_->{description},'vrfid'=>$ints->{$int}{vrfid},'id'=>$ints->{$int}{id}},$_->{ip});
        #print Dumper $_;
      }
    }
  }
  #clean up an leftover Nat configuration:
  for(keys %{$self->{currentnat}}){
    #print "deleting:".$_.':'.$self->{currentnat}{$_}."\n";
    $self->goNetbox('ipam/ip-addresses/',$self->{currentnat}{$_},'delete');
  }
  #print Dumper $natobj;
  print('=> NAT updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub updateIP{
  my ($self,$int,$i,$ip)=@_;
  my $ipbits=$ip->{ip}.'/'.$ip->{bits};
  $self->info("updating:".$int.' '.$ipbits);
  my $pfinfo=$self->getPrefix($int,$ip);
  my @except=('nat','arp','remote','mgmt');
  if($i->{vrfid}){
    my $payload->{address}=$ipbits;;
    $payload->{vrf}=$i->{vrfid};
    $payload->{tenant}=$self->{tenantid};
    $payload->{status}=1;
    $payload->{role}=41 if $ip->{type} eq 'vrrp';
    my $ipq='address='.$ipbits;
    $ipq.='&vrf_id='.$i->{vrfid};
    $payload='delete' if $i->{delete};
    my $ipid;
    my $ipret=$self->goNetbox('ipam/ip-addresses/?'.$ipq)->{results}[0];
    $ipid=$ipret->{id} if $ipret;
    if($ip->{type} eq 'arp'  && !$ipid){
      $payload->{description}='ARP for '.$self->{device}{hostname}.' '.$int;
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
      push(@{$self->{device}{arpadded}},$ipret->{id});
    }elsif($ip->{type} eq 'nat' && !$ipid){
      $payload->{description}='NAT for '.$i->{description};
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
      push(@{$self->{device}{natadded}},$ipret->{id});
    }elsif(!grep(/^$ip->{type}$/,@except)){
      $payload->{description}=$i->{description} if $i->{description};
      $payload->{interface}=$i->{id} if $i->{id};
      $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
    }
    if($ipret->{delete}){
      $ipret->{hostname}=$self->{device}{hostname};
      $ipret->{int}=$int;
      $ipret->{ip}=$ipbits;
    }
    if($ip->{ip} eq $self->{device}{mgmtip}){
      $self->{primary_ip}=$ip->{ip};
      $self->goNetbox('dcim/devices/',$self->{device}{id},{primary_ip4=>$ipret->{id}});
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
      #print "deleting:".$_."\n";
      my $del=$self->goNetbox('dcim/interface-connections/',$ch->{$_},'delete');
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
    $ri=~s/(.*)/$1.0/ if $ri=~/et-/ && $ri !~ /.*\.[\d]+$/;
    my $key=$int.':'.$rh.':'.$ri;
    my $altrh=_sub($rh);
    my $altkey=$int.':'.$altrh.':'.$ri;
    $self->_removeint($int);
    if(!$connhash->{$key} && !$connhash->{$altkey} && $ri !~/([\w:]+){5}[\w]+/){
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
      push(@{$self->{error}{warning}},"mac Connect ERROR: no match for $mac");
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
          $self->updateIP($int,$self->{device}{interfaces}{$int},$_);
        }
      }
    }
  }
  for(keys %{$self->{currentarp}}){
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

sub currentNAT{
  my $self = shift;
  my $ret=$self->goNetbox('ipam/ip-addresses/?q=NAT for '.$self->{device}{hostname}.'&limit=1000');
  if($ret->{count}>0){
    for(@{$ret->{results}}){
      $self->{currentnat}{$_->{address}}=$_->{id};
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
  $ffdict{'XFP-10G-SR'}=1300;
  $ffdict{'XFP-10G-LR'}=1300;
  $ffdict{'CAB-S-S-25G-1M'}=1350;
  $ffdict{'CAB-S-S-25G-3M'}=1350;
  $ffdict{'CAB-S-S-25G-2M'}=1350;
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
  $ffdict{'SFP-10G-SRL'}=1200;
  $ffdict{'SFP-10G-LR'}=1200;
  $ffdict{'SFPP30-03'}=1200;
  $ffdict{'SFPP30-02.5'}=1200;
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
  $ffdict{'DCS-7048T-A'}=1200;
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
