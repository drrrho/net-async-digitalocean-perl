package Net::Async::DigitalOcean::RateLimited;

use strict;
use warnings;
use Data::Dumper;

use Net::Async::HTTP;
use parent qw( Net::Async::HTTP );

sub prepare_request {
    my ($elf, $req) = @_;
#warn "prepare $elf";
    $elf->SUPER::prepare_request( $req );
    warn $req->as_string . " >>>> DigitalOcean" if $elf->{digitalocean_trace};

    if (my $limits = $elf->{digitalocean_rate_limit}) {                       # if we already experienced some limit information from the server
#warn "rate_limit current ".Dumper $limits;  # 

	my $backoff = $elf->{digitalocean_rate_limit_backoff} //= 0;          # default is to not wait

	my $absolute = $elf->{digitalocean_rate_limit_absolute} //= {         # compile it the policy into absolute values
	    map { ( $_ =~ /(\d+)\%/ 
		          ? $limits->{Limit} * $1 / 100
		          : $_) => $elf->{digitalocean_rate_limit_policy}->{$_} }
	    keys %{ $elf->{digitalocean_rate_limit_policy} } 
	};
#warn "absolute ".Dumper $absolute;
#warn "remaining ".$limits->{Remaining};
	foreach my $threshold ( sort keys %$absolute ) {                      # analyse - starting from the lowest
#warn "limit found $limits->{Remaining} < $threshold";
	    if ($limits->{Remaining} < $threshold) {                          # if we are already under that
		$backoff = &{$absolute->{ $threshold }} ( $backoff );         # compute new backoff, following the expression provided
		$backoff = 0 if $backoff < 0;                                 # dont want to go negative here
#warn "\\_ NEW backoff $backoff";
		last;                                                         # no further going up
	    }
	}
	
	$elf->{digitalocean_rate_limit_backoff} = $backoff;
#warn "have to wait $backoff ".$elf->loop;
	$elf->loop->delay_future( after => $backoff )->get if $backoff > 0;
#warn "\\_ done waiting";
    }

    return $req;
};

sub process_response {
    my ($elf, $resp) = @_;
    warn "DigitalOcean >>>> ".$resp->as_string if $elf->{digitalocean_trace};

    if ($elf->{digitalocean_rate_limit_policy}) { # if this is turned on
	if (my $limit = $resp->headers->header('RateLimit-Limit')) { # and if we actually got something
	    $elf->{digitalocean_rate_limit} = { Limit     => $limit,
						Remaining => $resp->headers->header('RateLimit-Remaining'),
						Reset     => $resp->headers->header('RateLimit-Reset'), };
	}
    }
    $elf->SUPER::process_response( $resp );
}

1;

package Net::Async::DigitalOcean;

use strict;
use warnings;

use JSON;
use Data::Dumper;
use HTTP::Status qw(:constants);

use Moose;

our $VERSION = '0.03';

use Log::Log4perl qw(:easy);
Log::Log4perl->easy_init($DEBUG);
no warnings 'once';
our $log = Log::Log4perl->get_logger("nado");

=head1 NAME

Net::Async::DigitalOcean - Asynchronous Library for DigitalOcean REST API

=head1 SYNOPSIS

=head1 xxxx

no classes, do not like over-engineering, JSON direct

spec



=head1 INTERFACE

=head2 Constructor

=cut

has 'loop'                 => (isa => 'IO::Async::Loop',             is => 'ro' );
has 'http'                 => (isa => 'Net::Async::HTTP',	     is => 'ro' );
has 'endpoint'             => (isa => 'Str',		             is => 'ro' );
has '_actions'             => (isa => 'HashRef', 		     is => 'ro', default => sub { {} });
has '_actionables'         => (isa => 'IO::Async::Timer::Periodic',  is => 'rw' );
has 'rate_limit_frequency' => (isa => 'Int|Undef',                   is => 'ro', default => 2);
has 'bearer'               => (isa => 'Str|Undef',                   is => 'ro' );

use constant DIGITALOCEAN_API => 'https://api.digitalocean.com/';
#TODO add v2

our $POLICY = {
    SUPER_DEFENSIVE => { 
       '100%' => sub { 0; },
	4810  => sub { $_[0] +  1; },
	'50%' => sub { $_[0] +  2; },
	'30%' => sub { $_[0] + 10; },
    } 
};

around BUILDARGS => sub {
    my $orig  = shift;
    my $class = shift;

    my %options = @_;

    $log->logdie ("IO::Async::Loop missing") unless $options{loop};

    my $endpoint = exists $options{endpoint}   # if user hinted that ENV can be used
                      ? delete $options{endpoint} // $ENV{DIGITALOCEAN_API}
                      : DIGITALOCEAN_API;
    $endpoint or $log->logdie ("no testing endpoint provided");

    my $bearer = delete $options{bearer} // $ENV{DIGITALOCEAN_BEARER}; # might be undef
    $log->logdie ("bearer token missing") if ! defined $bearer && $endpoint eq DIGITALOCEAN_API;

    my $throtteling = delete $options{throtteling} // $ENV{DIGITALOCEAN_THROTTELING}; # might be undef
    $throtteling = 1 if $endpoint eq DIGITALOCEAN_API; # no way around this

    my $tracing  = delete $options{tracing}; # only via that path

    use HTTP::Cookies;
    my $http = Net::Async::DigitalOcean::RateLimited->new(
	user_agent => "Net::Async::DigitalOcean $VERSION",
#	timeout    => 30,
	cookie_jar => HTTP::Cookies->new( 
	    file     => "$ENV{'HOME'}/.digitalocean-perl-cookies",
	    autosave => 1, ),
	);
    $http->configure( +headers => { 'Authorization' => "Bearer $bearer" } ) if defined $bearer;
    $http->{digitalocean_trace}             = 1                             if $tracing;
    $http->{digitalocean_rate_limit_policy} = $POLICY->{SUPER_DEFENSIVE}    if $throtteling;

    $options{loop}->add( $http );

    return $class->$orig (%options,
                          http         => $http,
			  endpoint     => $endpoint,
			  bearer       => $bearer,
			  %options,
                          );
};

=pod

=head2 Methods

=cut

sub start_actionables {
    my ($elf, $interval) = @_;

    $interval //= $elf->rate_limit_frequency;

    use IO::Async::Timer::Periodic;
    my $actionables = IO::Async::Timer::Periodic->new(
	interval => $interval,
	on_tick => sub {
#warn "tick";
	    my $actions = $elf->_actions; # handle

#	    my %done; # collect done actions here
	    foreach my $action ( values %$actions ) {
		my ($a, $f, $u, $r) = @$action;
# warn "looking at ".Dumper $a, $u, $r;
		next if $a->{status} eq 'completed';
		next unless defined $u;   # virtual actions
		$log->debug( "probing action $a->{id} for ".($a->{type}//$a->{rel}));
#warn "not completed asking for ".$a->{id}.' at '.$u;
# TODO type check
		my $f2 = _mk_json_GET_future( $elf, $u );
		$f2->on_done( sub {
#warn "action returned ".Dumper \@_;
		    my ($b) = @_; $b = $b->{action};
#warn "asking for action done, received ".Dumper $b;
		    if ($b->{status} eq 'completed') {
#warn "!!! completed with result $r".Dumper $r;
			if ($f->is_done) {                                   # this future has already been completed, THIS IS STRANGE
			    $log->warn("already completed action $a->{id} was again completed, ignoring...");
			} else {
			    $action->[0] = $b;                               # replace the pending action with the completed version
			    $f->done( $r ); # if                             # report this as done, but ...
			}
		    } elsif ($b->{status} eq 'errored') {
			$f->fail( $b );
		    }                                                        # not completed: keep things as they are
			      } );
	    }
#warn "done ".Dumper [ keys %done ];
#	    delete $actions->{$_} for keys %done;                 # purge actions
	},
	);
    $elf->_actionables( $actionables );
    $elf->http->loop->add( $actionables );
    $actionables->start;
}

sub stop_actionables {
    my ($elf) = @_;
    $elf->_actionables->stop;
}
    
#-- helper functions ---------------------------------------------------------------

sub _mk_json_GET_futures {
    my ($do, $path) = @_;

    $log->debug( "launching futures GET $path" );
    my $f = $do->http->loop->new_future;
#warn "futures setup ".$do->endpoint . $path;
    $do->http->GET(  $do->endpoint . $path  )
             ->on_done( sub {
		 my ($resp) = @_;
#warn "futures resp ".Dumper $resp;
		 if ($resp->is_success) {
		     if ($resp->content_type eq 'application/json') {
			 my $data = from_json ($resp->content);
			 if ($data->{links} && (my $next = $data->{links}->{next})) {     # we found a continuation
#warn "next $next";
			     $next  =~ /page=(\d+)/ or $log->logdie ("cannot find next page inside '$next'");
                             my $page = $1;
			     if ( $path =~ /page=/ ) {
				 $path =~ s/page=\d+/page=$page/;
			     } elsif ($path =~ /\?/) {
				 $path .= "&page=$page"
			     } else {
				 $path .= "?page=$page";
			 }
#warn "pager $page path '$path'";
			     $f->done( $data, $do->_mk_json_GET_futures( $path ) );
			 } else {
			     $f->done( $data, undef );
			 }
		     } else {
			 $f->fail( "sizes not JSON" );
		     }
		 } else {
		     my $message = $resp->message; chop $message;
		     $f->fail( $message );
		 }
			} )
	     ->on_fail( sub {
		 my ( $message ) = @_;
		 $log->logdie ("message from server '$message'");
			} );
    return $f;
}

sub _mk_json_GET_future {
    my ($do, $path) = @_;

    $log->debug( "launching future GET $path" );
    my $f = $do->http->loop->new_future;
    $do->http->GET(  $do->endpoint . $path  )
             ->on_done( sub {
		 my ($resp) = @_;
#warn Dumper $resp;
		 if ($resp->is_success) {
		     if ($resp->content_type eq 'application/json') {
			 $f->done( from_json ($resp->content) );
		     } else {
			 $f->fail( "sizes not JSON" );
		     }
		 } else {
		     my $message= $resp->message; chop $message;
		     $f->fail( $message );
		 }
			} )
	     ->on_fail( sub {
		 my ( $message ) = @_; chop $message;
		 $log->logdie ("message from server '$message'");
			} );
    return $f;
}

sub _handle_response {
    my ($do, $resp, $f) = @_;

#warn "handle response ".Dumper $resp;
    sub _message_crop {
	my $message = $_[0]->message; chop $message;
	return $message;
    }

    if ($resp->code == HTTP_OK) {
	$f->done( from_json ($resp->content) );

    } elsif ($resp->code == HTTP_NO_CONTENT) {
	$f->done( );

    # } elsif ($resp->code == HTTP_CREATED) {                                                                   # POST returned data
# 	if ($resp->content_type eq 'application/json') {                                                      # most likely another JSON here
# 	    my $data = from_json ($resp->content);
# #warn Dumper $data;
# 	    if (my $action = $data->{action}) {                                                               # if we only get an action to wait for
# #warn "got action".Dumper $action;
# 		$do->_actions->{ $action->{id} } = [ $action, $f, 'v2/actions/'.$action->{id}, 42 ];          # memory this, the future, and a reasonable final result
# 	    } else {                                                                                          # this looks insanly convoluted? I wholeheartedly agree.
# 	    }
# 	} else {
# 	    $f->fail( "returned not JSON" );
# 	}
    } elsif ($resp->code == HTTP_ACCEPTED
          || $resp->code == HTTP_CREATED) {                                                                   # for long-living actions
#warn "got accepted";
	if ($resp->content_type eq 'application/json') {
	    my $data = from_json ($resp->content);
#warn Dumper $data;
	    if (my $action = $data->{action}) {                                                               # if we only get an action to wait for
#warn "got action".Dumper $action;
		$do->_actions->{ $action->{id} } = [ $action, $f, 'v2/actions/'.$action->{id}, 42 ];          # memory this, the future, and a reasonable final result

	    } elsif (my $links = $data->{links}) {
#warn "link actions";
		if (my $res = $data->{droplet}) {
		    my $endpoint = $do->endpoint;
		    foreach my $action (@{ $links->{actions} }) {                                             # should probably be only one entry
#warn "action found ".Dumper $action;
			$action->{status} = 'in-progress';                                                    # faking it
			my $href = $action->{href};
			$href =~ s/$endpoint//; # remove endpoint to make href relative
			$do->_actions->{ $action->{id} } = [ $action, $f, $href, $res ];                      # memory this, the future, and a reasonable final result
		    }

		} elsif ($res = $data->{droplets}) {
#warn "preliminary result".Dumper $res;
		    my @fs;
		    my @ids;
#warn "got actions";
		    foreach my $action (@{ $links->{actions} }) {
#warn "action found ".Dumper $action;
			my $f2 = $do->http->loop->new_future;                                                 # for every action we create a future
			push @fs, $f2;                                                                        # collect the futures
			$action->{status} = 'in-progress';                                                    # faking it
			$do->_actions->{ $action->{id} } = [ $action, $f2, 'v2/actions/'.$action->{id}, 42 ]; # memorize this, the future, the URL and a reasonable final result
			push @ids, $action->{id};                                                             # collect the ids
		    }
#warn "ids ".Dumper \@ids;
		    my $f3 = Future->wait_all( @fs )                                                          # all these futures will be waited for to be done, before
			->then( sub {                                                                         # warn "all subfutures done ";
			    $f->done( $res );                                                                 # the final future can be called done
				} );
		    $do->_actions->{ join '|', @ids } = [ { id     => 'xxx'.int(rand(10000)),                 # id does not matter
							    rel    => 'compoud-create',                       # my invention
							    status => 'compound-in-progress' }, $f3, undef, $res ]; # compound, virtual action

		} else { # TODO, other stuff
		    warn "unhandled situation for ".Dumper $data;
		}
	    } elsif (my $actions = $data->{actions}) {                                                        # multiple actions bundled (e.g. reboot several droplets)
		my @fs;
		my @ids;
#warn "got actions";
		foreach my $action (@$actions) {
#warn "action found ".Dumper $action;
		    my $f2 = $do->http->loop->new_future;                                                     # for every action we create a future
		    push @fs, $f2; # collect the futures
		    $do->_actions->{ $action->{id} } = [ $action, $f2, 'v2/actions/'.$action->{id}, 42 ];     # memorize this, the future, the URL and a reasonable final result
		    push @ids, $action->{id};                                                                 # collect the ids
		}
		my $f3 = Future->wait_all( @fs )                                                              # all these futures will be waited for to be done, before
		    ->then( sub { # warn "all subfutures done ";
			$f->done( 42 );                                                                       # the final future can be called done
			    } );
		$do->_actions->{ join '|', @ids } = [ { id => 'xxx',                                          # id does not matter
							status => 'compound-in-progress' }, $f3, undef, 42 ]; # compound, virtual action
		
	    } else {
		$f->done( $data );
#		warn "not handled reaction from the server ".Dumper $data;
#		$f->done( 42 );
	    }
	} else {
	    $f->fail( "returned data not JSON" );
	}
    } elsif ($resp->is_redirect) {
	    $f->fail( _message_crop( $resp ) );

    } elsif ($resp->code == HTTP_TOO_MANY_REQUESTS) {
	my $json = $resp->content;
	my $data = from_json ($json);
#warn "message ".$data->{message};
	my $bounce_time; # agenda
	if ($data->{message} =~ /rate-limited.+?(\d+)m(\d+)s/) {                                               # detect a hint that this operation is limited
#warn ">>>$1<<>>$2<<<";
	    $bounce_time   = $1 * 60 + $2; # seconds
	    $bounce_time //= 30;           # default
	} else {
	    $bounce_time = 30;             # just guessing something
	}
	$log->info( "server sent HTTP_TOO_MANY_REQUEST => will have to wait for $bounce_time seconds, and then repeat request" );

	$do->loop->watch_time( after => $bounce_time,
			       code  => sub { 
				       $log->debug( "repeating previously failed request to ".$resp->request->uri );
				       $do->http->do_request( request => $resp->request )
					        ->on_done( sub {
						    my ($resp) = @_;
						    _handle_response( $do, $resp, $f );
							   } )
						->on_fail( sub {
						    my ( $message ) = @_; chop $message;
						    $log->logdie ("message from server '$message'");
							   } );
			       });


    } elsif (! $resp->is_success) {
#warn "failed request ".$resp->message . ' (' . $resp->code . ') '. $resp->content;
	if (my $json = $resp->content) {
	    my $data = from_json ($json);
#warn "error JSON ".Dumper $data;
	    $f->fail( $data->{message} );
	} else {
	    $f->fail( _message_crop( $resp ));
	}

    } else { # some other response
	warn "unhandled request ".$resp->message . ' (' . $resp->code . ') '. $resp->content;
	$f->fail( _message_crop( $resp ));
    }
}

sub _mk_json_POST_future {
    my ($do, $path, $body) = @_;

    $log->debug( "launching future POST $path" );

    my $f = $do->http->loop->new_future;
    $do->http->POST( $do->endpoint . $path,
		     to_json( $body), 
		     content_type => 'application/json' )
             ->on_done( sub {
		 my ($resp) = @_;
#warn "response ".Dumper $resp;
		 _handle_response( $do, $resp, $f );
			} )
	     ->on_fail( sub {
		 my ( $message ) = @_; chop $message;
#warn "XXXXX $message";
		 $log->logdie ("message from server '$message'");
			} );
    return $f;
}

sub _mk_json_PUT_future {
    my ($do, $path, $body) = @_;

    $log->debug( "launching future PUT $path" );
    my $f = $do->http->loop->new_future;
    $do->http->PUT( $do->endpoint . $path,
		     to_json( $body), 
		     content_type => 'application/json' )
             ->on_done( sub {
		 my ($resp) = @_;
#warn "response ".Dumper $resp;
		 _handle_response( $do, $resp, $f );
			} )
	     ->on_fail( sub {
		 my ( $message ) = @_; chop $message;
		 $log->logdie ("message from server '$message'");
			} );
    return $f;
}

sub _mk_json_DELETE_future {
    my ($do, $path) = @_;

    $log->debug( "launching future DELETE $path" );
    my $f = $do->http->loop->new_future;
    $do->http->do_request( uri    => $do->endpoint . $path,
			   method => "DELETE")
             ->on_done( sub {
		 my ($resp) = @_;
#warn Dumper $resp;
		 _handle_response( $do, $resp, $f );

		 # if ($resp->code == HTTP_NO_CONTENT) {
		 #     $f->done( );
		 # } elsif ($resp->code == HTTP_ACCEPTED) {
		 #     $f->done( );
		 # } else {
		 #     $f->fail( $resp->message );
		 # }
			} )
	     ->on_fail( sub {
		 my ( $message ) = @_; chop $message;
		 $log->logdie ("message from server '$message'");
			} );
    return $f;
}

#--

sub account {
    my ($do) = @_;
    return _mk_json_GET_future( $do, "v2/account" );
}

sub sizes {
    my ($do) = @_;
    return _mk_json_GET_future( $do, "v2/sizes" );
}

sub regions {
    my ($do) = @_;
    return _mk_json_GET_future( $do, "v2/regions"  );
}

sub create_volume {
    my ($do, $v) = @_;
    return _mk_json_POST_future( $do, 'v2/volumes', $v);
}
    
sub delete_volume {
    my ($do, $key, $val, $reg) = @_;

    if ($key eq 'id') {
	return _mk_json_DELETE_future( $do, 'v2/volumes/'. $val );

    } elsif ($key eq 'name') {
	return _mk_json_DELETE_future( $do, "v2/volumes?name=$val&region=$reg" );

    } else {
	$log->logdie ("invalid specification");
    }
}
    
sub volume {
    my ($do, $key, $val, $reg) = @_;

    if ($key eq 'id') {
	return _mk_json_GET_future( $do, "v2/volumes/$val" );
    } else {
	return _mk_json_GET_future( $do, "v2/volumes?name=$val&region=$reg" );
    }
}

sub volumes {
    my ($do, $key, $val) = @_;
    
    if (defined $key && $key eq 'name') {
	return _mk_json_GET_future( $do, "v2/volumes?name=$val" );
    } else {
	return _mk_json_GET_future( $do, 'v2/volumes' );
    }
}

sub volume_resize {
    my ($do, $vid, $resize) = @_;
    return _mk_json_POST_future( $do, "v2/volumes/$vid/actions", $resize);
}

sub volume_attach {
    my ($do, $vid, $attach) = @_;
    return _mk_json_POST_future( $do, "v2/volumes/$vid/actions", $attach);
}

sub create_snapshot {
    my ($do, $volid, $s ) = @_;
    return _mk_json_POST_future( $do, "v2/volumes/$volid/snapshots", $s);
}

sub delete_snapshot {
    my ($do, $id) = @_;
    return _mk_json_DELETE_future( $do, 'v2/snapshots/'. $id );
}

sub snapshots {
    my ($do, $key, $val ) = @_;

    if ($key eq 'volume') {
	return _mk_json_GET_future( $do, "v2/volumes/$val/snapshots");
    } elsif ($key eq 'droplet') {
	return _mk_json_GET_future( $do, "v2/droplets/$val/snapshots");
    } else {
	$log->logdie( "unhandled in method snapshots");
    }
}

sub backups {
    my ($do, $id ) = @_;
    return _mk_json_GET_future( $do, "v2/droplets/$id/backups");
}

sub images {
    my ($do, $key, $val) = @_;
    if ($key) {
	return _mk_json_GET_futures( $do, "v2/images?$key=$val");
    } else {
	return _mk_json_GET_futures( $do, "v2/images");
    }
}

sub images_all {
    my $do = shift;
    
    my $g = $do->http->loop->new_future;            # the HTTP request to be finished eventually
    my @l = ();                  # into this list all results will be collected

    my $f = $do->images( @_ );    # launch the first request (with the original parameters)
    _prepare( $f, \@l, $g );  # setup the reaction to the incoming response
    return $g;

    sub _prepare {
	my ($f, $l2, $g) = @_;
	$f->on_done( sub {                                                        # when the response comes in
	    (my $l, $f) = @_;                                                     # we get the result and (maybe) a followup future
	    push @$l2, @{ $l->{images} };                                         # accumulate the result
	    if (defined $f) {                                                     # if there is a followup
		_prepare( $f, $l2, $g );                                          # repeat and rinse
	    } else {
		$g->done( $l2 );  # we are done set this as overall result
	    }
		     } );
    }
}

sub create_droplet {
    my ($do, $v) = @_;
    return _mk_json_POST_future( $do, 'v2/droplets', $v);
}

sub delete_droplet {
    my ($do, $key, $val) = @_;

    if ($key eq 'id') {
	return _mk_json_DELETE_future( $do, "v2/droplets/$val" );
    } elsif ($key eq 'tag') {
	return _mk_json_DELETE_future( $do, "v2/droplets?tag_name=$val" );
    } else {
	$log->logdie( "unhandled in method delete_droplet" );
    }
}
    
sub droplet {
    my ($do, $key, $val, $reg) = @_;

    if ($key eq 'id') {
	return _mk_json_GET_future( $do, "v2/droplets/$val" );
    } else {
	return _mk_json_GET_future( $do, "v2/droplets?name=$val&region=$reg" );
    }
}

sub droplets {
    my ($do) = @_;
    return _mk_json_GET_futures( $do, "v2/droplets");
}

sub droplets_all { # helper function
    my ($do) = @_;

    my $g = $do->http->loop->new_future;
    my @l = ();

    my $f = $do->droplets;
    _iprepare( $f, \@l, $g );
    return $g;

    sub _iprepare {
	my ($f, $l2, $g) = @_;
	$f->on_done( sub {
	    (my $l, $f) = @_;
	    push @$l2, @{ $l->{droplets} };
	    if (defined $f) {
		_iprepare( $f, $l2, $g );
	    } else {
		$g->done( { droplets => $l2, meta => { total => scalar @$l2 } } );
	    }
		     } );
    }
}

sub perform_droplet_rename {
    my ($do, $key, $val, $name) = @_;
    _perform_droplet_action( $do, $key, $val, { type => 'rename', name => $name });
}

sub perform_droplet_rebuild {
    my ($do, $key, $val, $image) = @_;
    _perform_droplet_action( $do, $key, $val, { type => 'rebuild', image => $image });
}

sub perform_droplet_resize {
    my ($do, $key, $val, $size, $disk) = @_;
    _perform_droplet_action( $do, $key, $val, { type => 'resize', size => $size, disk => $disk });
}

sub _perform_droplet_backup {
    my ($do, $key, $val) = @_;
    _perform_droplet_action( $do, $key, $val, { type => 'backup' });
}

sub perform_droplet_restore {
    my ($do, $key, $val, $image) = @_;
    _perform_droplet_action( $do, $key, $val, { type => 'restore', image => $image });
}

sub perform_droplet_actions {
    my ($do, $key, $val, $type) = @_;
    _perform_droplet_action( $do, $key, $val, { type => $type });
}

sub _perform_droplet_action {
    my ($do, $key, $val, $body) = @_;

    if ($key eq 'id') {
	return _mk_json_POST_future( $do, "v2/droplets/$val/actions",          $body );
    } elsif ($key eq 'tag_name') {
	return _mk_json_POST_future( $do, "v2/droplets/actions?tag_name=$val", $body );
    } else {
	$log->logdie( "unhandled in method _perform_droplet_action" );
    }
}

sub droplet_actions {
    my ($do, $key, $val) = @_;

    if ($key eq 'id') {
	return _mk_json_GET_future( $do, "v2/droplets/$val/actions" );
    } elsif ($key eq 'tag_name') {
	$log->logdie( "unhandled in method droplet_actions" );
    } else {
	$log->logdie( "unhandled in method droplet_actions" );
    }
}

sub associated_resources {
    my ($do, $key, $val) = @_;

    if ($key eq 'id') {
	return _mk_json_GET_future( $do, "v2/droplets/$val/destroy_with_associated_resources" );
    } elsif ($key eq 'check_status') {
	return _mk_json_GET_future( $do, "v2/droplets/$val/destroy_with_associated_resources/status" );
    } else {
	$log->logdie( "unhandled in method associated_resources" );
    }
}
    
sub delete_with_associated_resources {
    my ($do, $key, $val) = @_;

    if ($key eq 'id') {
	return _mk_json_DELETE_future( $do, "v2/droplets/$val/destroy_with_associated_resources/dangerous" );
    } else {
	$log->logdie( "unhandled in method delete_with_associated_resources" );
    }
}
    
#-- domain

sub create_domain {
    my ($do, $d) = @_;
    return _mk_json_POST_future( $do, 'v2/domains', $d);
}

sub delete_domain {
    my ($do, $name) = @_;
    return _mk_json_DELETE_future( $do, 'v2/domains/'. $name );
}

sub domain {
    my ($do, $name) = @_;
    return _mk_json_GET_future( $do, "v2/domains/$name");
}

sub domains {
    my ($do) = @_;
    return _mk_json_GET_futures( $do, "v2/domains" );
}

#-- domain records

sub domain_records {
    my ($do, $name, %options) = @_;

    my @params;
    push @params, "type=$options{type}"
	if $options{type};
    push @params, "name=" . ($options{name} eq '@' ? $name : $options{name})
	if $options{name};

    return _mk_json_GET_futures( $do, "v2/domains/$name/records" .(@params ? '?'.join '&', @params : '') );
}

sub create_record {
    my ($do, $name, $r) = @_;
    return _mk_json_POST_future( $do, "v2/domains/$name/records", $r);
}

sub domain_record {
    my ($do, $name, $id) = @_;
    return _mk_json_GET_future( $do, "v2/domains/$name/records/$id");
}

sub update_record {
    my ($do, $name, $id, $r) = @_;
    return _mk_json_PUT_future( $do, "v2/domains/$name/records/$id", $r);
}

sub delete_record {
    my ($do, $name, $id) = @_;
    return _mk_json_DELETE_future( $do, "v2/domains/$name/records/$id");
}


sub create_key {
    my ($do, $key) = @_;
    return _mk_json_POST_future( $do, "v2/account/keys", $key);
}

sub key {
    my ($do, $id) = @_;
    return _mk_json_GET_future( $do, "v2/account/keys/$id");
}

sub keys {
    my ($do, $id) = @_;
    return _mk_json_GET_futures( $do, "v2/account/keys");
}

sub update_key {
    my ($do, $id, $key) = @_;
    return _mk_json_PUT_future( $do, "v2/account/keys/$id", $key);
}

sub delete_key {
    my ($do, $id) = @_;
    return _mk_json_DELETE_future( $do, "v2/account/keys/$id");
}

#-- meta API ------------------------------------------------

sub meta_reset {
    my ($do) = @_;
    return _mk_json_POST_future( $do, "meta/reset", {});
}

sub meta_ping {
    my ($do) = @_;
    return _mk_json_POST_future( $do, "meta/ping", {});
}

sub meta_account {
    my ($do, $v) = @_;
    return _mk_json_POST_future( $do, "meta/account", $v);
}

sub meta_statistics {
    my ($do) = @_;
    return _mk_json_GET_future( $do, "meta/statistics");
}

sub meta_capabilities {
    my ($do) = @_;
    return _mk_json_GET_future( $do, "meta/capabilities");
}


=pod

=head1 AUTHOR

Robert Barta, C<< <rho at devc.at> >>

=head1 LICENSE AND COPYRIGHT

Copyright 2021 Robert Barta.

This program is free software; you can redistribute it and/or modify it
under the terms of the the Artistic License (2.0). You may obtain a
copy of the full license at:

L<http://www.perlfoundation.org/artistic_license_2_0>

Any use, modification, and distribution of the Standard or Modified
Versions is governed by this Artistic License. By using, modifying or
distributing the Package, you accept this license. Do not use, modify,
or distribute the Package, if you do not accept this license.

If your Modified Version has been derived from a Modified Version made
by someone other than you, you are nevertheless required to ensure that
your Modified Version complies with the requirements of this license.

This license does not grant you the right to use any trademark, service
mark, tradename, or logo of the Copyright Holder.

This license includes the non-exclusive, worldwide, free-of-charge
patent license to make, have made, use, offer to sell, sell, import and
otherwise transfer the Package with respect to any patent claims
licensable by the Copyright Holder that are necessarily infringed by the
Package. If you institute patent litigation (including a cross-claim or
counterclaim) against any party alleging that the Package constitutes
direct or contributory patent infringement, then this Artistic License
to you shall terminate on the date that such litigation is filed.

Disclaimer of Warranty: THE PACKAGE IS PROVIDED BY THE COPYRIGHT HOLDER
AND CONTRIBUTORS "AS IS' AND WITHOUT ANY EXPRESS OR IMPLIED WARRANTIES.
THE IMPLIED WARRANTIES OF MERCHANTABILITY, FITNESS FOR A PARTICULAR
PURPOSE, OR NON-INFRINGEMENT ARE DISCLAIMED TO THE EXTENT PERMITTED BY
YOUR LOCAL LAW. UNLESS REQUIRED BY LAW, NO COPYRIGHT HOLDER OR
CONTRIBUTOR WILL BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL, OR
CONSEQUENTIAL DAMAGES ARISING IN ANY WAY OUT OF THE USE OF THE PACKAGE,
EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.


=cut


1;
