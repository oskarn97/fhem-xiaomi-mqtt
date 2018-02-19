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
    $hash->{AttrFn} = "MQTT::DEVICE::Attr";
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

    # Subscribe Readings
    my $newTopic = XiaomiMQTT::DEVICE::GetTopicFor($hash) . '#';
    my ($mqos, $mretain, $mtopic, $mvalue, $mcmd) = MQTT::parsePublishCmdStr($newTopic);
    client_subscribe_topic($hash, $mtopic, $mqos, $mretain);
    Log3($hash->{NAME}, 5, "automatically subscribed to topic: " . $newTopic);

    if($hash->{MODEL} eq 'bridge') {
      main::InternalTimer(main::gettimeofday()+2, "XiaomiMQTT::DEVICE::updateDevices", $hash, 1);
    }

    if (AttrVal($name, "stateFormat", "transmission-state") eq "transmission-state") {
        if ( $model eq 'sensor_ht') {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %';
        }
        elsif ( $model eq 'weather') {
            $main::attr{$name}{stateFormat}  = 'temperature °C, humidity %, pressure kPa';
        } elsif($model ne 'unknown') {
            $main::attr{$name}{stateFormat} = "state";
        }
        $hash->{STATE} = "paired";
    }

    if(!defined($main::attr{$name}{devStateIcon})) {
        if( $model =~ /motion/) {
            $main::attr{$name}{devStateIcon}  = 'motion:motion_detector@red off:motion_detector@green no_motion:motion_detector@green' ;
        }
        elsif ( $model =~ /magnet/) {
            $main::attr{$name}{devStateIcon}  = 'open:fts_door_open@red close:fts_door@green';
        }
    }

    return undef;
};

sub GetTopicFor {
    my ($hash, $cmnd) = @_;
    return 'xiaomi/'. (defined $cmnd ? 'cmnd/' : '') . $hash->{SID} . '/' . (defined $cmnd ? $cmnd : '');
}

sub Undefine($$) {
    my ($hash, $name) = @_;

    my $oldTopic = XiaomiMQTT::DEVICE::GetTopicFor($hash) . '#';
    client_unsubscribe_topic($hash, $oldTopic);
    delete($main::modules{XiaomiMQTTDevice}{defptr}{$hash->{SID}});

    Log3($hash->{NAME}, 5, "automatically unsubscribed from topic: " . $oldTopic);

    return MQTT::Client_Undefine($hash);
}

sub Set($$$@) {
    my ($hash, $name, $command, @values) = @_;

    if ($command eq '?') {
    	 my $cmdList = "";
	    if ($hash->{MODEL} eq "bridge") {
	    	$cmdList = "pairForSec updateDevices";
	    } else {
	    	$cmdList = "unpair:noArg";
	    }
        return "Unknown argument " . $command . ", choose one of ". $cmdList;
    }
    
    Log3($hash->{NAME}, 5, "set " . $command . " - value: " . join (" ", @values));


    my $msgid;
    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};

    if ($hash->{MODEL} eq "bridge") {
        if($command eq 'pairForSec') {
            my $topic = XiaomiMQTT::DEVICE::GetTopicFor($hash, 'pair');
            my $value = join (" ", @values);

            $msgid = send_publish($hash->{IODev}, topic => $topic, message => $value, qos => $qos, retain => $retain);

            Log3($hash->{NAME}, 5, "sent (cmnd) '" . $value . "' to " . $topic);
        }

        if ($command eq "updateDevices") {
            updateDevices($hash);
        }
    } else {
        if($command eq 'unpair') {
            my $topic = XiaomiMQTT::DEVICE::GetTopicFor($hash, 'unpair');
            $msgid = send_publish($hash->{IODev}, topic => $topic, message => "", qos => $qos, retain => $retain);

            Log3($hash->{NAME}, 5, "sent (cmnd) '' to " . $topic);
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
    if($parts[-2] eq $hash->{SID}) {
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

        if($path eq 'unpair') {
            fhem('delete '. $hash->{NAME});
            main::CommandSave(undef, undef);
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
    }

    else {
      # Forward to "normal" logic
        MQTT::DEVICE::onmessage($hash, $topic, $message);
    }
}

sub Decode($$$) {
    my ($hash, $reading, $value) = @_;
    my $h;

    eval {
        $h = JSON::decode_json($value);
        1;
    };

    if ($@) {
        Log3($hash->{NAME}, 2, "bad JSON: $reading: $value - $@");
        return undef;
    }

    readingsBeginUpdate($hash);
    XiaomiMQTT::DEVICE::Expand($hash, $h, $reading . "-", "");
    readingsEndUpdate($hash, 1);

    return undef;
}

sub Expand($$$$) {
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
            if (ref($value)) {
                XiaomiMQTT::DEVICE::Expand($hash, $value, $prefix . $key . $suffix . "-", "");
            } else {
                # replace illegal characters in reading names
                (my $reading = $prefix . $key . $suffix) =~ s/[^A-Za-z\d_\.\-\/]/_/g;
                readingsBulkUpdate($hash, lc($reading), $value);
            }
        }
    }
}

sub updateDevices($) {
	my ($hash) = @_;
    my $topic = XiaomiMQTT::DEVICE::GetTopicFor($hash, 'getDevices');

    my $retain = $hash->{".retain"}->{'*'};
    my $qos = $hash->{".qos"}->{'*'};
    my $msgid = send_publish($hash->{IODev}, topic => $topic, message => "", qos => $qos, retain => $retain);

    Log3($hash->{NAME}, 5, "sent (cmnd) '' to " . $topic);
}

1;
