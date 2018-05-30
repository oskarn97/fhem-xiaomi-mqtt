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

    my ($name, $type, $model, $id) = @args;

    $id = 'bridge' if(!defined $id);

    $hash->{MODEL} = $model;
    $hash->{SID} = $id;

    $hash->{TYPE} = 'MQTT_DEVICE';
    MQTT::Client_Define($hash, $def);
    $hash->{TYPE} = $type;
    $main::modules{XiaomiMQTTDevice}{defptr}{$id} = $hash;

    if($hash->{MODEL} eq 'bridge') {
        main::InternalTimer(main::gettimeofday()+2, "XiaomiMQTT::DEVICE::updateDevices", $hash, 1);
    }

    if (AttrVal($name, "stateFormat", "transmission-state") eq "transmission-state") {
        if ( $model =~ m/WSDCGQ01LM/) {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %';
        }
        elsif ( $model =~ m/WSDCGQ11LM/) {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %, pressure kPa';
        } elsif($model =~ m/unknown/) {
            $main::attr{$name}{stateFormat} = "state";
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
    }

    return undef;
};

sub Attr($$$$) {
    my ($command, $name, $attribute, $value) = @_;
    my $hash = $defs{$name};

    my $result = MQTT::DEVICE::Attr($command, $name, $attribute, $value);

    if ($attribute eq "IODev") {
        # Subscribe Readings
        my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr(XiaomiMQTT::DEVICE::GetTopicFor($hash));
        client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

        ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr('xiaomi/'. $hash->{SID}. '/#');
        client_subscribe_topic($hash, $mtopic, $mqos, $mretain);

        if($hash->{MODEL} eq 'bridge') {
            ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr("zigbee2mqtt/bridge/log");
            client_subscribe_topic($hash, $mtopic, $mqos, $mretain);
        }
    }

    return $result;
}


sub GetTopicFor {
    my ($hash) = @_;
    return "zigbee2mqtt/" . ($hash->{SID});
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
        return "Unknown argument " . $command . ", choose one of ". $cmdList;
    }
    
    Log3($hash->{NAME}, 5, "set " . $command . " - value: " . join (" ", @values));


    my $msgid;
    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};

    if ($hash->{MODEL} eq "bridge") {
        if($command eq 'pair' || $command eq 'pairForSec') {
            my $value = join (" ", @values);

            $msgid = send_publish($hash->{IODev}, topic => 'zigbee2mqtt/bridge/config/permit_join', message => $value == 0 ? "false" : "true", qos => $qos, retain => $retain);
            $msgid = send_publish($hash->{IODev}, topic => 'xiaomi/cmnd/bridge/pair', message => 220, qos => $qos, retain => $retain); #backwards compatibility
            main::RemoveInternalTimer($hash);
            main::InternalTimer(main::gettimeofday()+5*60, "XiaomiMQTT::DEVICE::endPairing", $hash, 1);
        }

        if ($command eq "updateDevices") {
            updateDevices($hash);
        }
    }


    $hash->{message_ids}->{$msgid}++ if defined $msgid;
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

    if($topic =~ m/bridge\/log/) {
        my $name = $hash->{NAME};
        my $json = eval { JSON->new->utf8(0)->decode($message) };
        if($json->{type} eq "devices") {
            foreach my $device (@{$json->{message}}) {
              my $sid = $device->{ieeeAddr};
              my $model = $device->{model};
              $model = 'unknown' if(!defined $model);
              if (!defined $main::modules{XiaomiMQTTDevice}{defptr}{$sid}) {
                Log3 $name, 4, "$name: DEV_Parse> UNDEFINED " . $model . " : " .$sid;
                main::DoTrigger("global", "UNDEFINED XMI_$sid XiaomiMQTTDevice $model $sid");
              } else {
                my $defined = $main::modules{XiaomiMQTTDevice}{defptr}{$sid};
                if($defined->{model} ne $model) {
                    fhem('modify '. $defined->{NAME} . ' '. $model . ' '. $sid);
                }
              }
            }

            main::CommandSave(undef, undef);
            return
        }

        if($json->{type} eq "device_connected") {
            updateDevices($hash);
        }
    }

    if($parts[-1] eq $hash->{SID}) {
        XiaomiMQTT::DEVICE::Decode($hash, $message);
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
            if (ref($value) && ref($value) ne "JSON::XS::Boolean") {
                XiaomiMQTT::DEVICE::Expand($hash, $value, $prefix . $key . $suffix . "-", "");
            } else {
                # replace illegal characters in reading names
                (my $reading = $prefix . $key . $suffix) =~ s/[^A-Za-z\d_\.\-\/]/_/g;
                if(ref($value) eq "JSON::XS::Boolean") {
                    $value = $value ? "true" : "false";
                }
                if($reading eq 'battery') {
                    readingsBulkUpdate($hash, 'battery_level', $value);
                    $value = $value < 80 ? 'low' : 'ok';
                }
                if($reading eq 'occupancy') {
                    readingsBulkUpdate($hash, 'state', $value eq "true" ? 'motion' : 'no_motion');
                }
                if($reading eq 'contact') {
                    readingsBulkUpdate($hash, 'state', $value eq "true" ? 'open' : 'close');
                }
                if($reading eq 'illuminance') {
                    readingsBulkUpdate($hash, 'lux', $value);
                }
                if($reading eq 'click') {
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
    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};
    my $msgid = send_publish($hash->{IODev}, topic => "zigbee2mqtt/bridge/config/devices", message => "", qos => $qos, retain => $retain);
    $msgid = send_publish($hash->{IODev}, topic => 'xiaomi/cmnd/bridge/getDevices', message => "", qos => $qos, retain => $retain); #backwards compatibility
}

sub endPairing {
    my ($hash) = @_;
    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};
    my $msgid = send_publish($hash->{IODev}, topic => "zigbee2mqtt/bridge/config/permit_join", message => "false", qos => $qos, retain => $retain); 
}

1;
