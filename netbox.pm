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
  $self->info($res);
  my $ret=0;
  if($res->{error}){
    push(@{$self->{error}},$res->{error});
  }else{
    if($res->{results}){
      my $rc=@{$res->{results}};
      if($rc==1){
        $ret=$res->{results}[0]{id};
      }
    }else{
      push(@{$self->{error}{warning}},"ERROR : getID : results for $p");
    }
  }
  return $ret;
}

sub getDeviceType{
  my $self = shift;
  my $cp='none';
  $cp=1 if $self->{device}{modules};
  $cp=0 if $self->{device}{parent};
  my $id=$self->getID('dcim/device-types/?model='.$self->{device}{model});
  if($id){
    if($cp ne 'none'){
      my $payload->{subdevice_role}=$cp;
      $payload->{u_height}=0 if $cp==0;
      $self->goNetbox('dcim/device-types/',$id,$payload)
    }
    return $id;
  }else{
    my $vendid=$self->getID('dcim/manufacturers/?slug='.lc($self->{device}{vendor}));
    my $payload->{model}=$self->{device}{model};
    $payload->{slug}=_slugify($self->{device}{model});
    $payload->{manufacturer}=$vendid;
    $payload->{u_height}=1;
    $payload->{u_height}=0 if $cp==0;
    $payload->{is_full_depth}='true';
    $payload->{subdevice_role}=$cp if $cp ne 'none';
    my $dtret=$self->goNetbox('dcim/device-types/','',$payload);
    if($dtret->{id}){
      return $dtret->{id};
    }else{
      push(@{$self->{error}{critical}},'ERROR:unable to find model name'.$self->{device}{model});
    }
  }
}

sub getPlatform{
  my $self = shift;
  my $vendor=$self->{device}{vendor};
  print "vendor:$vendor\n";
  my $platobj={
    "arista"=>"Arista EOS",
    "cisco"=>"Cisco IOS",
    "force10"=>"Dell FTOS",
    "juniper"=>"Juniper JUNOS"
  };
  if($platobj->{$vendor}){
    my $id=$self->getID('dcim/platforms/?name='.$platobj->{$vendor});
    if($id){
      return $id;
    }else{
      my $payload->{name}=$platobj->{$vendor};
      $payload->{slug}=lc($platobj->{$vendor});
      my $platret=$self->goNetbox('dcim/platforms/','',$payload);
      if($platret->{id}){
        return $platret->{id};
      }else{
        push(@{$self->{error}{warning}},'ERROR:unable to create platform type:'.$vendor.':'.$platobj->{$vendor});
        return '';
      }
    }
  }else{
    push(@{$self->{error}{warning}},'error: unable to match vendor with platform:'.$vendor);
    return '';
  }
}

sub getDeviceRole{
  my $self = shift;
  my $id=$self->getID('dcim/device-roles/?name='.$self->{device}{devicerole});
  if($id){
    return $id;
  }else{
    my $payload->{name}=$self->{device}{devicerole};
    $payload->{slug}=_slugify($self->{device}{devicerole});
    my $drret=$self->goNetbox('dcim/device-roles/','',$payload);
    if($drret->{id}){
      return $drret->{id};
    }else{
        push(@{$self->{error}{critical}},'ERROR:unable to find device role:'.$self->{device}{devicerole});
    }
  }
}


sub updateDevice{
  my $self = shift;
  my $t0 = [gettimeofday];
  if(!$self->{device}{serial}){
    push(@{$self->{error}{critical}},'ERROR:no serialnum found for '.$self->{device}{hostname});
    return;
  }
  my $devid;
  $devid=$self->getID('dcim/devices/?name='.$self->{device}{hostname});
  $devid=$self->getID('dcim/devices/?serial='.$self->{device}{serial}) if $self->{device}{vendor} ne 'opengear' && !$devid;
  $self->info('DEVICEID:'.$devid);

  my $payload->{status}=1;
  $payload->{comments}=$self->{device}{processor} if $self->{device}{processor};
  $payload->{serial}=$self->{device}{serial};
  $payload->{name}=$self->{device}{hostname};
  $payload->{device_type}=$self->getDeviceType();

  if(!$devid){
    $self->{isnew}='yes';
    my $geninfo=$self->goNetbox('dcim/sites/?q='.$self->{device}{sitename})->{results}[0];
    $geninfo=$self->goNetbox('dcim/sites/?q='._sub($self->{device}{sitename}))->{results}[0] if !$geninfo;
    if(!$geninfo){
      push(@{$self->{error}{critical}},'ERROR: unable to find information for site:'.$self->{device}{sitename});
      return;
    }else{
      $payload->{site}=$geninfo->{id};
      $payload->{device_role}=$self->getDeviceRole();
    }
  }else{
    $payload->{tags}=['network'];
    $payload->{face}=undef if $self->{device}{parent};
  }
  $self->info('=> updating device...');
  my $devret=$self->goNetbox('dcim/devices/',$devid,$payload);
  if($devret->{id}){
    #print Dumper $devret;
    $self->info('found id!');
    $self->{device}{modelid}=$devret->{device_type}{id};
    $self->{device}{id}=$devret->{id};
    $self->{siteid}=$devret->{site}{id};
    $self->{siteslug}=$devret->{site}{slug};
    $self->{device}{sitename}=$devret->{site}{name};
    $self->{primary_ip}=$devret->{primary_ip4};
    #if($devret->{rack} && $self->{device}{devicerole} eq 'PDU'){
    #  my $rackinfo=$self->goNetbox('dcim/racks/?id__in='.$devret->{rack}{id},'','');
    #  $self->{device}{room}=$rackinfo->{results}[0]{group}{name};
    #  $self->{device}{rack}=$rackinfo->{results}[0]{name}
    #}

    $self->addDeviceBay() if $self->{device}{parent};
    #$self->rackDevice() if !$devret->{rack};
    #print Dumper $self->{device}{gbics} if $self->{device}{gbics};
    $self->updateInventory('dimms') if $self->{device}{dimms};
    $self->updateInventory('slots') if $self->{device}{slots};
    $self->updateInventory('gbics') if $self->{device}{gbics};
  }else{
    push(@{$self->{error}{critical}},'ERROR: unable to update device:'.$self->{device}{hostname});
  }
  print('=> Device updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub addDeviceBay{
  my $self = shift;
  my $dbret=$self->goNetbox('dcim/device-bays/?device_id='.$self->{device}{parent}.'&name='.$self->{device}{cardname});
  my $payload;
  if($dbret->{count}>0){
    $payload->{installed_device}=$self->{device}{id} if $dbret->{results}[0]{installed_device}{id} ne $self->{device}{id};
  }else{
    $payload->{name}=$self->{device}{cardname};
    $payload->{device}=$self->{device}{parent};
    $payload->{installed_device}=$self->{device}{id};
  }
  $self->goNetbox('dcim/device-bays/',$dbret->{results}[0]{id},$payload) if $payload;
}

sub findRack{
  my $self = shift;
  my $rack=$self->{device}{rack};
  my $rret=$self->goNetbox('dcim/racks/?site_id='.$self->{siteid}.'&group_id='.$self->{rackgroupid}.'&q='.$rack);
  if($rret->{count}>0){
    for(@{$rret->{results}}){
      if(
      $_->{name} eq $rack ||
      $_->{name} eq uc($rack) ||
      $_->{name} eq lc($rack) ||
      $_->{name}=~/[0]+$rack/i
      ){
        return $_->{id};
      }
    }
  }
}

sub rackDevice{
  my $self = shift;
  if(($self->{device}{unum} || $self->{device}{devicerole} eq 'PDU') && $self->{device}{room}){
    my $groupid=$self->getID('dcim/rack-groups/?name='.$self->{device}{room}.'&site_id='.$self->{siteid});
    if($groupid){
      $self->{rackgroupid}=$groupid;
      my $rackid=$self->findRack();
      if($rackid){
        $self->{rackid}=$rackid;
      }else{
        $self->info('adding rack!');
        $self->addRack();
      }
      if($self->{rackid}){
        my $unum=$self->{device}{unum};
        my $position=$unum;
        if($unum){
          my $modelret=$self->goNetbox('dcim/device-types/'.$self->{device}{modelid}.'/');
          my $u_height=$modelret->{u_height};
          $position=($unum-$u_height)+1;
        }
        my $payload->{rack}=$self->{rackid};
        $payload->{position}=$position;
        $payload->{face}=0;
        my $rdret=$self->goNetbox('dcim/devices/',$self->{device}{id},$payload);
        if(!$rdret->{id}){
          push(@{$self->{error}{warning}},'ERROR: unable to rack device:'.$self->{device}{room}.':'.$self->{device}{rack}.':unum:'.$self->{device}{unum});
        }
      }else{
        push(@{$self->{error}{warning}},'ERROR: unable to add rack :'.$self->{device}{room}.':'.$self->{device}{rack}.':unum:'.$self->{device}{unum});
      }
    }else{
      push(@{$self->{error}{warning}},'ERROR: unable to find rack group:'.$self->{device}{room});
    }
  }else{
    push(@{$self->{error}{warning}},'ERROR: no unum found, room:'.$self->{device}{room}.' rack:'.$self->{device}{rack});
  }
}

sub addRack{
  my $self = shift;
  my $rackname=$self->{device}{rack};
  my $uh;
  if($self->{device}{sitename}=~/us-east-1[abc]/){
    $uh=62;
  }else{
    $uh=45;
  }
  $rackname=~s/^([1-9][\d]{2,4})$/0$1/i;
  my $payload->{name}=$self->{device}{rack};
  $payload->{facility_id}=$self->{device}{rack}.':'.$self->{device}{room}.':'.$self->{device}{sitename};
  $payload->{site}=$self->{siteid};
  $payload->{group}=$self->{rackgroupid};
  $payload->{u_height}=$uh;
  my $rackret=$self->goNetbox('dcim/racks/','',$payload);
  if($rackret->{id}){
    $self->{rackid}=$rackret->{id}
  }
}

sub updateInventory{
  my ($self,$key)=@_;
  my $inv=$self->{device}{$key};
  my $nbinv=$self->{dcache}{$key};
  #my $nbinv;
  for(keys %{$inv}){
    my $i=$_;
    if(!$nbinv->{$i}){
      my $id=$self->getID('dcim/inventory-items/?name='.$inv->{$i}{name}.'&device_id='.$self->{device}{id});
      if($id){
        $inv->{$i}{id}=$id;
      }else{
        $inv->{$i}{device}=$self->{device}{id};
        my $iret=$self->goNetbox('dcim/inventory-items/','',$inv->{$i});
        if($iret->{id}){
          $inv->{$i}{id}=$iret->{id};
        }else{
          push(@{$self->{error}{critical}},'ERROR: unable to add inventory item:'.$inv->{$i}{name});
        }
      }
    }
  }
  for(keys %{$nbinv}){
    if(!$inv->{$_}){
      my $iret=$self->goNetbox('dcim/inventory-items/',$nbinv->{id},'delete');
    }
  }
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
        $payload->{vrf}=$pfret->{vrfid};
        $payload->{interface}=$intid;
        $ipret=$self->goNetbox('ipam/ip-addresses/','',$payload);
        $self->goNetbox('dcim/devices/',$self->{device}{id},{primary_ip4=>$ipret->{id}});
      }
    }else{
      push(@{$self->{error}{warning}},'ERROR: unable to set primary ip '.$self->{device}{hostname});
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
  $self->{device}{arpints}=0;
  $self->{device}{connints}=0;
  my $devints=$self->{device}{interfaces};
  my $nbxints=$self->{dcache}{interfaces};
  $nbxints=$self->getcurrentInterfaces() if !$nbxints;
  my $vlc=0;
  my @intupdate;
  my @retints;
  my @lags;
  for my $int (keys %{$devints}){
    #$self->info('int:'.$int);
    $vlc++ if $devints->{$int}{vlans};
    $self->{device}{arpints}=$self->{device}{arpints}+1 if $devints->{$int}{arp};
    $self->{device}{connints}=$self->{device}{connints}+1 if $devints->{$int}{macs} or $devints->{$int}{lldp};
    if($devints->{$int}{macs}){
      if($devints->{$int}{formfactor} eq 'LAG'){
        my $physint=$devints->{$int}{children}[0];
        my $machold=$devints->{$int}{macs};
        delete $devints->{$int}{macs};
        for(@{$machold}){
          push(@{$devints->{$physint}{macs}},$_);
        }
      }
    }
    my ($devdescr,$nbxdescr,$devip,$nbxip)=('','','','');
    $devdescr=$devints->{$int}{description} if $devints->{$int}{description};
    $nbxdescr=$nbxints->{$int}{description} if $nbxints->{$int}{description};
    if($devdescr ne $nbxdescr || !$nbxints->{$int}{formfactor}){
      #delete $self->{currentints}{$int};
      #print "adding:".$int.':'.$devints->{$int}{formfactor}."\n";
      push(@intupdate,$int)
    }
  }
  for my $int (keys %{$nbxints}){
    if(!$devints->{$int}){
      $self->info("marking $int for deletion!");
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
    $self->getnbvlans if $vlc>0;
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
  my $intobj;
  my $intret;
  if($self->{device}{vendor} eq 'opengear'){
    $intret=$self->goNetbox('dcim/console-server-ports/?limit=1000&device_id='.$self->{device}{id})->{results};
  }else{
    $intret=$self->goNetbox('dcim/interfaces/?limit=1000&device_id='.$self->{device}{id})->{results};
  }
  for(@{$intret}){
    $intobj->{$_->{name}}={id=>$_->{id}};
  }
  return $intobj;
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
    my $vlret=$self->goNetbox('ipam/vlans/','',$payload);
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
  my $intid=$self->getID('dcim/console'.$server.'-ports/?device_id='.$self->{device}{id}.'&name='.$int);
  my $intret;
  if(!$intid && $i->{delete}){
    delete $self->{device}{interfaces}{$int};
  }elsif($i->{delete}){
    $intret=$self->goNetbox('dcim/console'.$server.'-ports/',$intid,'delete');
    delete $self->{device}{interfaces}{$int};
  }else{
    my $payload->{device}=$self->{device}{id};
    $payload->{name}=$int;
    $intid=$self->goNetbox('dcim/console'.$server.'-ports/',$intid,$payload)->{id} if !$intid;
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
    return
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
    $payload->{mac_address}=$i->{localmac} if $i->{localmac};
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
    my $obj={id=>$_->{id},vrfid=>$_->{vrf}{id},network=>$network,bits=>$bits};
    if($ret){
      if($ret->{bits}<$bits){
        $ret=$obj;
      }
    }else{
      $ret=$obj;
    }
  }
  return $ret;
}

sub prefixFromStatic{
  my $self = shift;
  $self->info('adding static routes...');
  for(@{$self->{device}{statics}}){
    my ($net,$bits)=($_->{net},$_->{bits});
    my $pfret=$self->goNetbox('ipam/prefixes/?contains='.$_->{net}.'&mask_length='.$_->{bits});
    if($pfret->{count}<1){
      my $payload->{prefix}=$net.'/'.$bits;
      $payload->{site}=$self->{siteid};
      #$payload->{vrf}=$self->{device}{interfaces}{$int}{vrfid};
      #$payload->{vlan}=$vlanid if $vlanid;
      $payload->{description}='from static on '.$self->{device}{hostname};
      $payload->{is_pool}='true';
      my $ret=$self->goNetbox('ipam/prefixes/','',$payload);
      push(@{$self->{error}{warning}},'ERROR: updating prefix:'.$net) if !$ret->{id};
    }
  }
}

sub getPrefix{
  my ($self,$int,$ip) = @_;
  my $bits=$ip->{bits};
  $bits=31 if $bits=='32';
  my $ninet = new NetAddr::IP $ip->{ip}.'/'.$bits;
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
  my $intid=$self->{device}{interfaces}{$int}{id};
  my ($vrfname,$payload);
  if(!$vrf){
    $vrfname='global';
  }else{
    $vrfname=$self->{siteslug}.' '.$vrf;
    my $rd=$intid.':'.$self->{siteid};
    $payload->{name}=$vrfname;
    $payload->{rd}=$rd;
    $payload->{enforce_unique}='true';
  }
  my $ret=$self->goNetbox('ipam/vrfs/?q='.$vrfname);
  if($ret->{count}<1){
    $ret=$self->goNetbox('ipam/vrfs/','',$payload);
    if(!$ret->{id}){
      push(@{$self->{error}{critical}},'Unable to add VRF:'.$int.':'.$vrfname) if !$ret->{id};
    }
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
sub fixARP{
  my ($self,$iplist)=@_;
  my $na=0;
  for(@{$iplist}){
    print Dumper $_;
    $na++ if $_->{description} !~/^ARP for.*/;
  }
  if($na>0){
    for(@{$iplist}){
      $self->info('adding to currentarp:'.$_->{address}.':'.$_->{id}) if $_->{description} =~/^ARP for.*/;
      push(@{$self->{delarp}},$_->{id}) if $_->{description} =~/^ARP for.*/;
    }
  }
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
    $payload->{status}=1;
    $payload->{role}=41 if $ip->{type} eq 'vrrp';
    my $ipq='address='.$ipbits.'&vrf_id='.$i->{vrfid};
    $ipq='address='.$ip->{ip} if $ip->{type} eq 'arp';
    $payload='delete' if $i->{delete};
    my $ipid;
    my $ipinfo=$self->goNetbox('ipam/ip-addresses/?'.$ipq);
    my $ipret=$ipinfo->{results}[0];
    $ipid=$ipret->{id} if $ipret;
    if($ip->{type} eq 'arp'){
      if(!$ipid){
        $payload->{description}='ARP for '.$self->{device}{hostname}.' '.$int;
        $ipret=$self->goNetbox('ipam/ip-addresses/',$ipid,$payload);
        push(@{$self->{device}{arpadded}},$ipret->{id});
      }elsif($ipinfo->{count}>1){
        $self->fixARP($ipinfo->{results});
      }
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

sub buildOOBconnhash{
  my $self=shift;
  my $cl=$self->goNetbox('dcim/console-connections/?device='.$self->{device}{hostname});
  if($cl->{'count'}>0){
    for(@{$cl->{results}}){
      $self->{connhash}{$_->{device}{name}}=$_->{cable}{id};
    }
  }
  $self->info('conhash built');
}

sub buildconnhash{
  my $self=shift;
  my $cl=$self->goNetbox('dcim/interface-connections/?device='.$self->{device}{hostname}.'&limit=1000');
  if($cl->{'count'}>0){
    for(@{$cl->{results}}){
      my $res=$_;
      if($res->{interface_a}{device}{name} eq $self->{device}{hostname}){
        $self->_addconn($res,'a','b');
      }elsif($res->{interface_b}{device}{name} eq $self->{device}{hostname}){
        $self->_addconn($res,'b','a');
      }
    }
  }
  #print Dumper $self->{connhash};
  $self->info('conhash built');
}

sub _addconn{
  my ($self,$res,$a,$b)=@_;
  my ($bdev,$aint,$bint);
  my $ia='interface_'.$a;
  my $ib='interface_'.$b;
  $aint=$res->{$ia}{name};
  $bdev=$res->{$ib}{device}{name};
  $bint=$res->{$ib}{name};
  my $altbdev=_sub($bdev);
  $altbdev=~s/-service/-ss/i;
  $self->{connhash}{$aint.':'.$bdev.':'.$bint}=$_->{$ib}{cable};
  $self->{connhash}{$aint.':'.$altbdev.':'.$bint}=$_->{$ib}{cable};
}

sub _removeint{
  my ($self,$int)=@_;
  for(keys %{$self->{connhash}}){
    $self->info("int: $int connhold: $_") if $_=~/^$int:/;
    $self->{connhold}{$_}='hold' if $_=~/^$int:/;
  }
}

sub _slugify{
  my $s=shift;
  $s=lc($s);
  $s=~s/\s+/-/g;
  return $s;
}

sub _sub{
  my $n =  shift;
  my $altsub={
    'ap-northeast'=>'ap-ne',
    'ap-southeast'=>'ap-se',
    'eu-central'=>'eu-c',
    'eu-c-'=>'eu-central-',
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
  print "=> Updating connections...\n";
  my $t0 = [gettimeofday];
  if($self->{device}{vendor} eq 'opengear'){
    $self->buildOOBconnhash();
  }else{
    $self->buildconnhash();
  }

  my $ints=$self->{device}{interfaces};
  for(keys %{$ints}){
    #todo need to update the connections to specify different cable types
    $self->connectConsole($_) if $self->{device}{vendor} eq 'opengear';
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
      $self->info("deleting:".$_);
      my $del=$self->goNetbox('dcim/cables/',$ch->{$_},'delete');
    }
  }
  print('=> Connections updated in '.sprintf("%.2fs\n", tv_interval ($t0)));
}

sub connectConsole{
  my ($self,$int) = @_;
  my $t0 = [gettimeofday];
  my $connhash=$self->{connhash};
  my $i=$self->{device}{interfaces}{$int};
  $self->{connhold}{$i->{label}}='hold';
  if(!$self->{connhash}{$i->{label}} && $i->{label} !~/^(Port|Front\sUSB)\s.*/i){
    my $intid=$self->goNetbox('dcim/console-server-ports/?device_id='.$self->{device}{id}.'&name='.$int)->{results}[0]{id};
    if($intid){
      my $rmdevret=$self->goNetbox('dcim/devices/?q='.$i->{label})->{results};
      if(@{$rmdevret}==1){
        my $cpid=$self->getID('dcim/console-ports/?device_id='.$rmdevret->[0]{id});
        if($cpid){
          my $payload->{termination_a_id}=$cpid;
          $payload->{termination_a_type}='dcim.consoleport';
          $payload->{termination_b_id}=$intid;
          $payload->{termination_b_type}='dcim.consoleserverport';
          my $cableret=$self->goNetbox('dcim/cables/','',$payload);
          push(@{$self->{error}{warning}},'console:unable to connect device'.$rmdevret->[0]{name}) if !$cableret->{id};
        }
      }elsif(@{$rmdevret}>1){
        push(@{$self->{error}{warning}},'console:too many device matches'.@{$rmdevret}.' '.$i->{label});
      }else{
        push(@{$self->{error}{warning}},'console:no devices found for '.$i->{label});
      }
    }else{
      push(@{$self->{error}{warning}},'console:unable to find local interface:'.$int);
    }
    print('==>'.$int.' Console connected in '.sprintf("%.2fs\n", tv_interval ($t0)));
  }
}

sub connectLLDP{
  my ($self,$int) = @_;
  my $t0 = [gettimeofday];
  my $connhash=$self->{connhash};
  my $ints=$self->{device}{interfaces};
  $self->info('working lldp on '.$int);
  for(@{$ints->{$int}{lldp}}){
    my $rh=$_->{rh};
    my $ri=$_->{ri};
    $self->info('lldp:'.$rh.':'.$ri);
    $ri=~s/Gi/GigabitEthernet/ if $ri=~/Gi[\d]/;
    $ri=~s/(.*)/$1.0/ if $ri=~/et-/ && $ri !~ /.*\.[\d]+$/;
    my $key=$int.':'.$rh.':'.$ri;
    my $altrh=_sub($rh);
    $altrh=~s/-service/-ss/i;
    my $altkey=$int.':'.$altrh.':'.$ri;
    $self->_removeint($int);

    if(!$connhash->{$key} && !$connhash->{$altkey}){
      $self->info('lldpkey:'.$key.' lldpaltkey:'.$altkey.' ri:'.$ri);
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
          my $payload={"termination_a_id"=>$nblintid,"termination_b_id"=>$nbrintid};
          $payload->{termination_a_type}="dcim.interface";
          $payload->{termination_b_type}="dcim.interface";
          $payload->{type}=1500;
          my $conninfo=$self->goNetbox('dcim/cables/','',$payload);
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
    $self->info("int:$int mac:$mac\n");
    my $macresults=$self->goNetbox('dcim/interfaces/?mac_address='.$mac)->{results};
    my $nbmacinfo={};
    for(@{$macresults}){
      if($_->{device}{name} && !$_->{cable}){
        $nbmacinfo=$_;
      }
    }
    my ($nbmacid,$rh,$ri)=($nbmacinfo->{id},$nbmacinfo->{device}{name},$nbmacinfo->{name});
    if($nbmacid && $rh){
      my $key=$int.':'.$rh.':'.$ri;
      my $altrh=_sub($rh);
      my $altkey=$int.':'.$altrh.':'.$ri;
      $self->_removeint($int);
      $self->_removeint($ints->{$int}{children}[0]) if $ints->{$int}{children}[0];
      if(!$connhash->{$key} && !$connhash->{$altkey}){
        my $nbintid=$ints->{$int}{id};
        $nbintid=$self->getID('dcim/interfaces/?name='.$ints->{$int}{children}[0].'&device_id='.$self->{device}{id}) if $ints->{$int}{children}[0];
        $nbintid=$self->getID('dcim/interfaces/?name='.$int.'&device_id='.$self->{device}{id}) if !$nbintid;
        if($nbintid){
          $ints->{$int}{id}=$nbintid;
          my $payload={"termination_a_id"=>$nbintid,"termination_b_id"=>$nbmacid};
          $payload->{termination_a_type}="dcim.interface";
          $payload->{termination_b_type}="dcim.interface";
          $payload->{type}=1500;
          my $conninfo=$self->goNetbox('dcim/cables/','',$payload);
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
  $self->{delarp}=[];
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
          if($self->{currentarp}{$ipnet}){
            delete $self->{currentarp}{$ipnet};
          }else{
            push(@addarp,$_);
          }
        }
      }

      if(!$ints->{$int}{id} && @addarp>0){
        my $intid=$self->getID('dcim/interfaces/?device_id='.$self->{device}{id}.'&name='.$int);
        $ints->{$int}{id}=$intid;
        $ints->{$int}{vrfid}=$self->getVRFid($int);
      }

      for(@addarp){
        my $ipnet=$_->{ip}.'/'.$_->{bits};
        #print "ipnet:$ipnet \n";
        if(!$self->{currentarp}{$ipnet} && $_->{bits}){
          $self->updateIP($int,$self->{device}{interfaces}{$int},$_);
        }
      }
    }
  }
  for(keys %{$self->{currentarp}}){
    $self->goNetbox('ipam/ip-addresses/',$self->{currentarp}{$_},'delete');
  }
  for(@{$self->{delarp}}){
    $self->goNetbox('ipam/ip-addresses/',$_,'delete');
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
  $ffdict{'SFP1G-SX-85'}=1100;
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
  $ffdict{'QSFP-40G-SR4'}=1400;
  $ffdict{'QSFP-LR4-40G'}=1400;
  $ffdict{'QSFP-SR4-40G'}=1400;
  $ffdict{'Q-4SPC03'}=1400;
  $ffdict{'QSFP28100GBASE-LR4'}=1600;
  $ffdict{'QSFP28100GBASE-LR4-LITE'}=1600;
  $ffdict{'QSFP28100GBASE-SR4'}=1600;
  $ffdict{'QSFP28-IR4-100G'}=1600;
  $ffdict{'QSFP-100G-SR4'}=1600;
  $ffdict{'QSFP-100G-CWDM4'}=1600;
  $ffdict{'QSFP-100G-LR4'}=1600;
  $ffdict{'QSFP28-LR4-100G'}=1600;
  $ffdict{'QSFP28-SR4-100G'}=1600;
  $ffdict{'CAB-Q-Q-100G-1M'}=1600;
  $ffdict{'CAB-Q-Q-100G-5M'}=1600;
  $ffdict{'SM100G-SR'}=1600;
  $ffdict{'SFP+10G-ER'}=1200;
  $ffdict{'SFP+10G-LR'}=1200;
  $ffdict{'SFP+10G-SR'}=1200;
  $ffdict{'SFP-10G-SR'}=1200;
  $ffdict{'SFP-10G-SRL'}=1200;
  $ffdict{'SFP+10GBASE-CU4M'}=1200;
  $ffdict{'616740003'}=1200;
  $ffdict{'4WJ41'}=1200;
  $ffdict{'SFP-10G-LR'}=1200;
  $ffdict{'SFPP30-03'}=1200;
  $ffdict{'SFPP30-02.5'}=1200;
  $ffdict{'SFP-10GLR-31'}=1200;
  $ffdict{'SFP-10GSR-85'}=1200;
  $ffdict{'SFPP30-01.5'}=1200;
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
  $ffdict{'UNSUPPORTED'}=32767;
  $ffdict{'CFPX-200G-DWDM'}=32767;
  return \%ffdict;
}

1;
