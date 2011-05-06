package Catalyst::Engine::Stomp;
use Moose;
use List::MoreUtils qw/ uniq /;
use HTTP::Request;
use Net::Stomp;
use MooseX::Types::Moose qw/Str Int HashRef/;
use namespace::autoclean;
use Encode;

extends 'Catalyst::Engine::Embeddable';

our $VERSION = '0.15';

has connection => (is => 'rw', isa => 'Net::Stomp');
has conn_desc => (is => 'rw', isa => Str);

=head1 NAME

Catalyst::Engine::Stomp - write message handling apps with Catalyst.

=head1 SYNOPSIS

  # In a server script:

  BEGIN {
    $ENV{CATALYST_ENGINE} = 'Stomp';
    require Catalyst::Engine::Stomp;
  }

  MyApp->config(
    Engine::Stomp' = {
       tries_per_server => 3,
      'servers' => [
       {
         'hostname' => 'localhost',
         'port' => '61613'
       },
       {
         'hostname' => 'stomp.yourmachine.com',
         'port' => '61613'
       },
       utf8             => 1,
       subscribe_header => {
         transformation       => 'jms-to-json',
       }
    },
  );
  MyApp->run();

  # In a controller, or controller base class:
  use base qw/ Catalyst::Controller::MessageDriven /;

  # then create actions, which map as message types
  sub testaction : Local {
      my ($self, $c) = @_;

      # Reply with a minimal response message
      my $response = { type => 'testaction_response' };
      $c->stash->{response} = $response;
  }

=head1 DESCRIPTION

Write a Catalyst app connected to a Stomp messagebroker, not HTTP. You
need a controller that understands messaging, as well as this engine.

This is single-threaded and single process - you need to run multiple
instances of this engine to get concurrency, and configure your broker
to load-balance across multiple consumers of the same queue.

Controllers are mapped to Stomp queues, and a controller base class is
provided, Catalyst::Controller::MessageDriven, which implements
YAML-serialized messages, mapping a top-level YAML "type" key to
the action.

=head1 FAILOVER

You can specify one or more servers in a list for the apps config.
This enables fail over if an error occurs, like the broker or network
connection disappears.

It will try to use a server a set number of times, as determined by
tries_per_server in the config before failing on to the next server
in the list. It cycle through each server in turn, going back to the
start of the list if need be.

=head1 UTF-8

By default STOMP messages are assumed to be in UTF-8. This module can
automatically convert a Perl string into a UTF-8 set of octets to be
sent over the wire instead. This is a Good Thing, especially if you 
use the function Load() from the package YAML::XS to un-serialize
it in your client - it assumes it is in UTF-8.

If you do want this behaviour, set 'utf8' to '1' in your config.

=head1 Simplified configuration

Instead of using the complete config layout as shown in the synopsis,
you can

=over 4

=item *

not specify a C<tries_per_server> (defaults to 1)

=item *

specify a single server:

  server => { hostname => $host, port => $port }

=item *

use the old-style (pre 0.14) config having C<hostname> and C<port>
directly in the C<Engine::Stomp> block, without a C<server> key in
between.

=back

=cut

=head1 METHODS

=head2 _see_ya

Set to run when signal USR1 is received. Simply sets the stop flag.

=cut

my $stop = 0;

sub _see_ya {
    $stop = 1;
    delete $SIG{'USR1'};
}


=head2 run

App entry point. Starts a loop listening for messages.

If the stop flag is set (see _see_ya above) then no more requests are processed.
Keep in mind this is a blocking server and it will wait for a STOMP message forever.
Only after handling a request does it check the flag.

=cut

sub run {
    my ($self, $app, $oneshot) = @_;

    $SIG{'USR1'} = \&_see_ya;

    die 'No Engine::Stomp configuration found'
        unless ref $app->config->{'Engine::Stomp'} eq 'HASH';

    my @queues = uniq grep { length $_ }
                 map  { $app->controller($_)->action_namespace } $app->controllers;

    # connect up
    my $config = $app->config->{'Engine::Stomp'};
    my $index  = 0;

    # munge the configuration to make it easier to write
    $config->{tries_per_server} ||= 1;
    $config->{connect_retry_delay} ||= 15;
    if (! $config->{servers} ) {
        $config->{servers} = [ {
            hostname => (delete $config->{hostname}),
            port => (delete $config->{port}),
        } ];
    }
    elsif (ref $config->{servers} eq 'HASH') {
        $config->{servers} = [ $config->{servers} ];
    }

    QUITLOOP:
    while (1) {
        # Go to next server in list
        my %template = %{ $config->{servers}->[$index] };
        $config->{hostname} = $template{hostname};
        $config->{port}     = $template{port};

        ++$index;

        if ($index >= (scalar( @{$config->{servers}} ))) {
            $index = 0; # go back to first server in list
        }

        my $tries = 0;

        while ($tries < $config->{tries_per_server}) {
            ++$tries;
    
            eval {
                my $subscribe_headers = $template{subscribe_headers} || {};
                die("subscribe_headers config for Engine::Stomp must be a hashref!\n")
                    if (ref($subscribe_headers) ne 'HASH');

                $app->log->info("Connecting to STOMP Q at " . $template{hostname}.':'.$template{port});

                $self->connection(Net::Stomp->new(\%template));
                $self->connection->connect();
                $self->conn_desc($template{hostname}.':'.$template{port});

                # subscribe, with client ack.
                foreach my $queue (@queues) {
                    my $queue_name = "/queue/$queue";
                    $self->connection->subscribe({
                        %$subscribe_headers,
                        destination => $queue_name,
                        ack         => 'client',
                    });
                }

                # Since we might block for some time, lets flush the log messages
                $app->log->_flush() if $app->log->can('_flush');

                # enter loop...
                while (1) {
                    my $frame = $self->connection->receive_frame(); # block
                    $self->handle_stomp_frame($app, $frame);
            
                    if ( $ENV{ENGINE_ONESHOT} || $stop ){
                        # Perl does not like 'last QUITLOOP' inside an eval, hence we die and do it
                        die "QUITLOOP\n";
                    }
                }
            };

            if (my $err=$@) {
                # although it looks like a lot of pointless flush()ing we need
                # to make sure the user(s) can see any new messages; we
                # sometimes die before we flush() in the loop above

                if ($err eq "QUITLOOP\n") {
                    last QUITLOOP;
                }
                else {
                    $app->log->error(" Problem dealing with STOMP : $err");
                    $app->log->_flush() if $app->log->can('_flush');
                }

                # don't loop continuously if we can't connect; take a break;
                # give the service a chance to come back
                if ($err =~ m{Connection refused}) {
                    $app->log->info(
                          'Unable to connect to '
                        . $template{hostname}.':'.$template{port}
                        . '; sleeping before next retry'
                    );
                    $app->log->_flush() if $app->log->can('_flush');
                    sleep $config->{connect_retry_delay};
                }
            }
        }
    }
}

=head2 prepare_request

Overridden to add the source broker to the request, in place of the
client IP address.

=cut

sub prepare_request {
    my ($self, $c, $req, $res_ref) = @_;
    shift @_;
    $self->next::method(@_);
    $c->req->address($self->conn_desc);
}

=head2 finalize_headers

Overridden to dump out any errors encountered, since you won't get a #'
"debugging" message as for HTTP.

=cut

sub finalize_headers {
    my ($self, $c) = @_;
    my $error = join "\n", @{$c->error};
    if ($error) {
        $c->log->debug($error);
    }
    return $self->next::method($c);
}

=head2 handle_stomp_frame

Dispatch according to Stomp frame type.

=cut

sub handle_stomp_frame {
    my ($self, $app, $frame) = @_;

    my $command = $frame->command();
    if ($command eq 'MESSAGE') {
        $self->handle_stomp_message($app, $frame);
    }
    elsif ($command eq 'ERROR') {
        $self->handle_stomp_error($app, $frame);
    }
    else {
        $app->log->debug("Got unknown Stomp command: $command");
    }
}

=head2 handle_stomp_message

Dispatch a Stomp message into the Catalyst app.

=cut

sub handle_stomp_message {
    my ($self, $app, $frame) = @_;

    # queue -> controller
    my $queue = $frame->headers->{destination};
    my ($controller) = $queue =~ m|^/queue/(.*)$|;

    # set up request
    my $config = $app->config->{'Engine::Stomp'};
    my $url = 'stomp://'.$config->{hostname}.':'.$config->{port}.'/'.$controller;
    my $req = HTTP::Request->new(POST => $url);
    $req->content($frame->body);
    $req->content_length(length $frame->body);

    # dispatch
    my $response;
    $app->handle_request($req, \$response);

    # reply, if header set
    if (my $reply_to = $response->headers->header('X-Reply-Address')) {
        my $reply_queue = '/remote-temp-queue/' . $reply_to;
        my $content     = $response->content;

        if ($config->{utf8}) {
            $content = encode("utf8", $response->content); # create octets
        }

        $self->connection->send({ destination => $reply_queue, body => $content });
    }

    # ack the message off the queue now we've replied / processed
    $self->connection->ack( { frame => $frame } );
}

=head2 handle_stomp_error

Log any Stomp error frames we receive.

=cut

sub handle_stomp_error {
    my ($self, $app, $frame) = @_;

    my $error = $frame->headers->{message};
    $app->log->debug("Got Stomp error: $error");
}

__PACKAGE__->meta->make_immutable;

=head1 CONFIGURATION

=head2 subscribe_header

Add additional header key/value pairs to the subscribe message sent to the
message broker.

=cut

=head1 DEVELOPMENT

The source to Catalyst::Engine::Stomp is in github:

  http://github.com/pmooney/catalyst-engine-stomp

=head1 AUTHOR

Chris Andrews C<< <chris@nodnol.org> >>

=head1 CONTRIBUTORS

Tomas Doran (t0m) C<< <bobtfish@bobtfish.net> >>

Jason Tang

Paul Mooney

=head1 LICENCE AND COPYRIGHT

Copyright (C) 2009 Venda Ltd

This library is free software; you can redistribute it and/or modify
it under the same terms as Perl itself, either Perl version 5.8.8 or,
at your option, any later version of Perl 5 you may have available.

=cut

