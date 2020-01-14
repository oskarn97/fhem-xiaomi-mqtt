##############################################
#
# fhem xiaomi bridge to mqtt (see http://mqtt.org)
#
# written 2018 by Oskar Neumann
# thanks to Matthias Kleine
#
##############################################

use strict;
use warnings;

sub XiaomiMQTTDevice_Initialize($) {
    my $hash = shift @_;

    # Consumer
    $hash->{DefFn} = "XiaomiMQTT::DEVICE::Define";
    $hash->{UndefFn} = "XiaomiMQTT::DEVICE::Undefine";
    $hash->{SetFn} = "XiaomiMQTT::DEVICE::Set";
    #$hash->{GetFn} = "XiaomiMQTT::DEVICE::Get";
    $hash->{AttrFn} = "XiaomiMQTT::DEVICE::Attr";
    $hash->{AttrList} = "IODev qos retain " . $main::readingFnAttributes;
    $hash->{OnMessageFn} = "XiaomiMQTT::DEVICE::onmessage";
    $hash->{RenameFn} = "XiaomiMQTT::DEVICE::Rename";

    main::LoadModule("MQTT");
    main::LoadModule("MQTT_DEVICE");
}

package XiaomiMQTT::DEVICE;

use strict;
use warnings;
use POSIX;
use SetExtensions;
use GPUtils qw(:all);

use Net::MQTT::Constants;
use JSON;


BEGIN {
    MQTT->import(qw(:all));

    GP_Import(qw(
        CommandDeleteReading
        CommandAttr
        readingsSingleUpdate
        readingsBulkUpdate
        readingsBeginUpdate
        readingsEndUpdate
        Log3
        fhem
        defs
        AttrVal
        ReadingsVal
    ))
};

sub Define() {
    my ($hash, $def) = @_;
    my @args = split("[ \t]+", $def);

    return "Invalid number of arguments: define <name> XiaomiMQTTDevice <model> [<id>]" if (int(@args) < 1);

    my ($name, $type, $model, $id, $friendlyName) = @args;
    $id = 'bridge' if(!defined $id);
    $friendlyName = $id if(!defined $friendlyName);

    $hash->{MODEL} = $model;
    $hash->{SID} = $id;
    $hash->{FRIENDLYNAME} = $friendlyName;

    $hash->{TYPE} = 'MQTT_DEVICE';
    MQTT::Client_Define($hash, $def);
    $hash->{TYPE} = $type;
    $main::modules{XiaomiMQTTDevice}{defptr}{$id} = $hash;

    if($model eq 'bridge') {
        main::InternalTimer(main::gettimeofday()+2, "XiaomiMQTT::DEVICE::updateDevices", $hash);
    }
    elsif ( $model =~ m/ROUTER/ ) {
    	$hash->{".lastHeartbeat"} = 0;
    	main::InternalTimer(main::gettimeofday()+80, "XiaomiMQTT::DEVICE::stateTimeout", $hash);
	}

    if (AttrVal($name, "stateFormat", "transmission-state") eq "transmission-state") {
        if ( $model =~ m/WSDCGQ01LM/) {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %';
        }
        elsif ( $model =~ m/WSDCGQ11LM/) {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %, pressure hPa';
        }
        elsif ($model =~ m/AB3257001NJ/){ # OSRAM Smart+ plug
            $main::attr{$name}{stateFormat} =  "state";
            $main::attr{$name}{webCmd} =  "toggle:on:off";
            $main::attr{$name}{devStateIcon} =  "ON:on OFF:off";
        }
        elsif($model =~ m/unknown/) {
            $main::attr{$name}{stateFormat} =  "state";
        }
        $hash->{STATE} = "paired";
    }

    if(!defined($main::attr{$name}{devStateIcon})) {
        if( $model =~ m/(RTCGQ11LM|RTCGQ01LM|motion)/ ) {
            $main::attr{$name}{devStateIcon}  = 'motion:motion_detector@red off:motion_detector@green no_motion:motion_detector@green' ;
        }
        elsif ( $model =~ m/(MCCGQ11LM|MCCGQ01LM|magnet)/ ) {
            $main::attr{$name}{devStateIcon}  = 'open:fts_door_open@red close:fts_door@green';
        }
        elsif ( $model =~ m/ROUTER/ ) {
        	$main::attr{$name}{devStateIcon}  = 'online:10px-kreis-gruen offline:10px-kreis-rot';
        }
    }

    if(!defined($main::attr{$name}{icon})) {
        if ( $model =~ m/ROUTER/ ) {
             $main::attr{$name}{icon}  = 'it_wifi';
        }
    }

    return "No MQTT IODev found." if(!defined($main::attr{$name}{IODev}));

    SubscribeReadings($hash);
    updateFriendlyName($hash);

    $hash->{'.autoSubscribeExpr'} = "\$a"; #never auto subscribe to anything, prevents log messages
    return undef;
};

sub Attr($$$$) {
    my ($command, $name, $attribute, $value) = @_;
    my $hash = $defs{$name};

    my $result = MQTT::DEVICE::Attr($command, $name, $attribute, $value);

    if ($attribute eq "IODev") {
        #SubscribeReadings($hash);
    }

    return $result;
}

sub Rename($$) {
    my ($old_name, $new_name) = @_;
    my $hash = $defs{$old_name};
    updateFriendlyName($hash);
}

sub updateFriendlyName {
    my ($hash) = @_;
    return if($hash->{MODEL} eq 'bridge');

    my $name = $hash->{NAME};
    my $friendlyName = $hash->{FRIENDLYNAME};

    if($friendlyName ne $name && (!defined $hash->{".renameFriendly"} || $hash->{".renameFriendly"} ne $name) && !($name eq $hash->{SID} && $hash->{SID} ne $friendlyName)) {
        Log3($name, 3, "Renaming MQTT Topic for " . $name . " from ". $friendlyName . " to ". $name);
        $hash->{".renameFriendly"} = $name;
        publish($hash, 'zigbee2mqtt/bridge/config/rename', encode_json({"old" => $friendlyName, "new" => $name}));
        updateDevices($hash);
    }
}

sub SubscribeReadings {
    my ($hash) = @_;
    my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr(XiaomiMQTT::DEVICE::GetTopicFor($hash));
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

    ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('xiaomi/'. $hash->{SID}. '/#');
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

    if($hash->{MODEL} eq 'bridge') {
        ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr("zigbee2mqtt/bridge/#");
        client_subscribe_topic($hash, $mtopic, $mqos, $mretain);
    }
}

sub GetTopicFor {
    my ($hash) = @_;
    return "zigbee2mqtt/" . $hash->{FRIENDLYNAME};
}

sub Undefine($$) {
    my ($hash, $name) = @_;

    client_unsubscribe_topic($hash, XiaomiMQTT::DEVICE::GetTopicFor($hash));
    client_unsubscribe_topic($hash, 'xiaomi/'. $hash->{SID}. '/#');
    client_unsubscribe_topic($hash, 'zigbee2mqtt/bridge/log') if($hash->{MODEL} eq 'bridge');

    delete($main::modules{XiaomiMQTTDevice}{defptr}{$hash->{SID}});
    return MQTT::Client_Undefine($hash);
}

sub Set($$$@) {
    my ($hash, $name, $command, @values) = @_;

    if ($command eq '?') {
         my $cmdList = "";
        if ($hash->{MODEL} eq "bridge") {
            $cmdList = "pair:1,0 updateDevices:noArg";
        } 
        # OSRAM Smart+ plug
        elsif ($hash->{MODEL} eq "AB3257001NJ"){
            $cmdList = "state:on,off remove:noArg";
        }
        else {
            $cmdList = "remove:noArg";
        }
        return "Unknown argument " . $command . ", choose one of ". $cmdList;
    }
    
    Log3($hash->{NAME}, 5, "set " . $command . " - value: " . join (" ", @values));

    my $value = join (" ", @values);
    my $values = @values;

    if ($hash->{MODEL} eq "bridge") {
        if($command eq 'pair' || $command eq 'pairForSec') {
            publish($hash, 'zigbee2mqtt/bridge/config/permit_join', $value == 0 ? "false" : "true");
            publish($hash, 'xiaomi/cmnd/bridge/pair', 220); #backwards compatibility
            main::RemoveInternalTimer($hash);
            main::InternalTimer(main::gettimeofday()+5*60, "XiaomiMQTT::DEVICE::endPairing", $hash, 1);
        }

        if ($command eq "updateDevices") {
            updateDevices($hash);
        }
    } else {
        if($command eq 'remove') {
            return publish($hash, "zigbee2mqtt/bridge/config/remove", $hash->{SID});
        }

        if($values == 0) {
            $value = $command;
            $command = "state";
        }

        publish($hash, XiaomiMQTT::DEVICE::GetTopicFor($hash) . "/set", encode_json({"state" => "ON"})) if($command eq "brightness");
        publish($hash, XiaomiMQTT::DEVICE::GetTopicFor($hash) . "/set", encode_json({$command => $value}));
    }
}

sub Get($$$@) {
    my ($hash, $name, $command, @values) = @_;

    #if ($command eq '?') {
    #    return "Unknown argument " . $command . ", choose one of " . join(" ", map { "$_$gets{$_}" } keys %gets) . " " . join(" ", map {$hash->{gets}->{$_} eq "" ? $_ : "$_:".$hash->{gets}->{$_}} sort keys %{$hash->{gets}});
    #}
}

sub onmessage($$$) {
    my ($hash, $topic, $message) = @_;

    Log3($hash->{NAME}, 5, "received message '" . $message . "' for topic: " . $topic);
    my @parts = split('/', $topic);
    my $path = $parts[-1];

    if($parts[-2] eq "bridge") {
        if($path eq "log") {
            my $name = $hash->{NAME};
            my $json = eval { JSON->new->utf8(0)->decode($message) };
            if($json->{type} eq "devices") {
                foreach my $device (@{$json->{message}}) {
                  my $sid = $device->{ieeeAddr};
                  my $friendlyName = $device->{friendly_name};
                  $friendlyName = $sid if(!defined $friendlyName);
                  $friendlyName =~ s/ //g;
                  my $model = $device->{model};
                  $model = 'unknown' if(!defined $model);
                  $model =~ s/ //g;
                  if (!defined $main::modules{XiaomiMQTTDevice}{defptr}{$sid}) {
                    Log3 $name, 4, "$name: DEV_Parse> UNDEFINED " . $model . " : " .$sid;
                    main::DoTrigger("global", "UNDEFINED $friendlyName XiaomiMQTTDevice $model $sid". ($sid ne $friendlyName ? " ". $friendlyName : ""));
                  } else {
                    my $defined = $main::modules{XiaomiMQTTDevice}{defptr}{$sid};
                    if($defined->{MODEL} ne $model || $defined->{FRIENDLYNAME} ne $friendlyName) {
                        client_unsubscribe_topic($defined, XiaomiMQTT::DEVICE::GetTopicFor($defined));
                        fhem('modify '. $defined->{NAME} . ' '. $model . ' '. $sid . ($sid ne $friendlyName ? " ". $friendlyName : ""));
                    }
                  }
                }

                main::CommandSave(undef, undef);
            } elsif($json->{type} eq "device_connected") {
                updateDevices($hash);
            } elsif($json->{type} eq "device_removed") {
                my $sid = $json->{message};
                my $defined = $main::modules{XiaomiMQTTDevice}{defptr}{$sid};
                if(defined $defined) {
                    fhem('delete '. $defined->{NAME});
                    main::CommandSave(undef, undef);
                }
            }
        }

        readingsSingleUpdate($hash, $path, $message, 1);
    }

    if($parts[-1] eq $hash->{SID} || ($parts[-1] eq $hash->{FRIENDLYNAME})) {
        XiaomiMQTT::DEVICE::Decode($hash, $message);
        readingsSingleUpdate($main::modules{XiaomiMQTTDevice}{defptr}{"bridge"}, 'transmission-state', 'incoming publish received', 1) if(defined $main::modules{XiaomiMQTTDevice}{defptr}{"bridge"});
    } elsif($parts[-2] eq $hash->{SID} && $parts[0] eq "xiaomi") { #backward compatibility, not needed with new fork
        my $path = $parts[-1];

        if($path eq 'devices') {
            my $name = $hash->{NAME};
            my $json = eval { JSON->new->utf8(0)->decode($message) };
            foreach my $device (@{$json}) {
              my $sid = $device->{sid};
              my $model = $device->{model};
              $model = 'unknown' if(!defined $model);
              if (!defined $main::modules{XiaomiMQTTDevice}{defptr}{$sid}) {
                Log3 $name, 4, "$name: DEV_Parse> UNDEFINED " . $model . " : " .$sid;
                main::DoTrigger("global", "UNDEFINED XMI_$sid XiaomiMQTTDevice $model $sid");
              }
            }

            return;
        }

        if($path eq 'model' && $message =~ m/[A-Za-z]/) {
            return if($message eq $hash->{MODEL});
            my @args = split("[ \t]+", $hash->{DEF});
            shift @args;
            fhem('modify '. $hash->{NAME} . ' '. $message . ' '. join(' ', @args));
            main::CommandSave(undef, undef);
            return;
        }

        if($path eq 'battery_level') {
            readingsSingleUpdate($hash, 'battery', $message > 2200 ? 'ok' : 'low', 1);
        }

        readingsSingleUpdate($hash, $path, $message, 1);
    } else {
        # Forward to "normal" logic
        MQTT::DEVICE::onmessage($hash, $topic, $message);
    }
}

sub Decode($$) {
    my ($hash, $value) = @_;
    my $h;

    eval {
        $h = JSON::decode_json($value);
        1;
    };

    if ($@) {
        Log3($hash->{NAME}, 2, "bad JSON: $value - $@");
        return undef;
    }

    readingsBeginUpdate($hash);
    if($hash->{MODEL} =~ m/ROUTER/ && defined $h->{description} && defined $h->{type} && defined $h->{rssi}) {
    	my $infos = {description => $h->{description}, type => $h->{type}, rssi => $h->{rssi}};
    	my (undef, $sid) = split('/', lc($h->{description}), 2);
    	$sid = 'bridge' if($h->{type} eq 'COORD');
    	my $dev = $main::modules{XiaomiMQTTDevice}{defptr}{$sid};
    	my $friendlyName = $sid;
    	$friendlyName = $dev->{FRIENDLYNAME} if(defined $dev);
    	delete $h->{description};
    	delete $h->{type};
    	delete $h->{rssi};
    	XiaomiMQTT::DEVICE::Expand($hash, $infos, $friendlyName . '_', "");
    }
    
    XiaomiMQTT::DEVICE::Expand($hash, $h, "", "");
    readingsEndUpdate($hash, 1);

    return undef;
}

sub Expand {
    my ($hash, $ref, $prefix, $suffix) = @_;

    $prefix = "" if (!$prefix);
    $suffix = "" if (!$suffix);
    $suffix = "-$suffix" if ($suffix);

    if (ref($ref) eq "ARRAY") {
        while (my ($key, $value) = each @{$ref}) {
            XiaomiMQTT::DEVICE::Expand($hash, $value, $prefix . sprintf("%02i", $key + 1) . "-", "");
        }
    } elsif (ref($ref) eq "HASH") {
        while (my ($key, $value) = each %{$ref}) {
            if (ref($value) && !(ref($value) =~ m/Boolean/)) {
                XiaomiMQTT::DEVICE::Expand($hash, $value, $prefix . $key . $suffix . "-", "");
            } else {
                # replace illegal characters in reading names
                (my $reading = $prefix . $key . $suffix) =~ s/[^A-Za-z\d_\.\-\/]/_/g;
                if(ref($value) =~ m/Boolean/) {
                    $value = $value ? "true" : "false";
                }

                if($reading eq 'battery') {
                    $reading = 'battery_level';
                    readingsBulkUpdate($hash, 'battery', $value <= 10 ? 'low' : 'ok');
                }
                if($reading eq 'occupancy') {
                    readingsBulkUpdate($hash, 'state', $value eq "true" ? 'motion' : 'no_motion');
                }
                if($reading eq 'contact') {
                    my $newVal = $value eq "true" ? 'close' : 'open';
                    readingsBulkUpdate($hash, 'state', $newVal) if(ReadingsVal($hash->{NAME}, 'state', '') ne $newVal);
                }
                if($reading eq 'illuminance') {
                    readingsBulkUpdate($hash, 'lux', $value);
                }
                if($reading eq 'state' && $hash->{MODEL} =~ m/ROUTER/) {
                	$reading = 'value';
                	readingsBulkUpdate($hash, 'state', 'online') if(ReadingsVal($hash->{NAME}, 'state', '') ne 'online');
                	$hash->{".lastHeartbeat"} = main::gettimeofday();
                	main::InternalTimer(main::gettimeofday()+80, "XiaomiMQTT::DEVICE::stateTimeout", $hash, 1);
                }

                if($reading eq 'click') {
                    if($hash->{MODEL} eq 'WXKG03LM') {
                        readingsBulkUpdate($hash, 'channel_0', 'click');
                    } elsif($hash->{MODEL} eq 'WXKG02LM') {
                        readingsBulkUpdate($hash, 'channel_'. ($value eq 'left' ? 0 : ($value eq 'right' ? 1 : 2)), 'click');
                    }
                    my $previousValue = $value;
                    $value = 'click_release' if($value eq 'single');
                    $value = 'double_click' if($value eq 'double');
                    $value = 'long_click_release' if($value eq 'long_release');
                    $value = $value . '_click' if($value eq $previousValue);
                    readingsBulkUpdate($hash, 'state', $value);
                    $value = $previousValue;
                }
                readingsBulkUpdate($hash, lc($reading), $value);
            }
        }
    }
}

sub updateDevices($) {
    my ($hash) = @_;
    publish($hash, "zigbee2mqtt/bridge/config/devices", "");
    publish($hash, 'xiaomi/cmnd/bridge/getDevices', ""); #backwards compatibility
}

sub endPairing {
    my ($hash) = @_;
    my $msgid = publish($hash, "zigbee2mqtt/bridge/config/permit_join", "false"); 
}

sub publish {
    my ($hash, $topic, $message) = @_;
    my $msgid = send_publish($hash->{IODev}, topic => $topic, message => $message, qos => 1, retain => 0); 
    $hash->{message_ids}->{$msgid}++ if(defined $msgid);
}

sub stateTimeout {
	my ($hash) = @_;
	return if(!($hash->{MODEL} =~ m/ROUTER/) || main::gettimeofday() - $hash->{".lastHeartbeat"} < 60);
	readingsSingleUpdate($hash, 'state', 'offline', 1);
}

1;