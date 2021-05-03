use strict;
use warnings;

use Test::More;
use Test::Exception;

use Data::Dumper;
$Data::Dumper::Indent = 1;

my $warn = shift @ARGV;
unless ($warn) {
    close STDERR;
    open (STDERR, ">/dev/null");
    select (STDERR); $| = 1;
}

use constant DONE => 1;

use JSON;
use HTTP::Status qw(:constants);

use IO::Async::Loop;
my $loop = IO::Async::Loop->new;

# $ENV{DIGITALOCEAN_API} //= 'http://0.0.0.0:8080/';

use Net::Async::DigitalOcean;

eval {
    Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );
}; if ($@) {
    plan skip_all => 'no endpoint defined ( e.g. export DIGITALOCEAN_API=http://0.0.0.0:8080/ )';
    done_testing;
}

{ # initalize and reset server state
    my $do = Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );
    $do->meta_reset->get;
}

if (DONE) {
    my $AGENDA = q{ssh_keys: };

    my $do = Net::Async::DigitalOcean->new( loop => $loop, endpoint => undef );

    my $f;
#--
    $f = $do->create_key( { name => 'test1', public_key => 'qsdfsdssddsfsdfs' } );
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future');
    my $k = $f->get; $k = $k->{ssh_key};
    is( $k->{name},       'test1',            $AGENDA.'name accepted');
    is( $k->{public_key}, 'qsdfsdssddsfsdfs', $AGENDA.'public key accepted');
#warn Dumper $k;
#--
    throws_ok {
	$do->create_key( { name => 'test1', public_key => 'qsdfsdssddsfsdfs2222' } )->get;
    } qr/already/, $AGENDA.'create of existing';
    my $k2 = $do->create_key( { name => 'test2', public_key => 'qsdfsdssddsfsdfs2222' } )->get; $k2 = $k2->{ssh_key};
#-- fetch
    $f = $do->key( $k2->{id} );
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future');
    my $k3 = $f->get; $k3 = $k3->{ssh_key};
    is_deeply($k3, $k2, $AGENDA.'fetched key');
    ok( defined $k2->{id},          $AGENDA.'fetched id set');
    ok( defined $k2->{fingerprint}, $AGENDA.'fetched fingerprint set');

#-- list
    $f = $do->keys;
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future');
    my $ks = $f->get;
#warn Dumper $ks;
    ok( eq_set([ map { $_->{name} }        @{ $ks->{ssh_keys} } ], [ qw(test1 test2) ]), $AGENDA.'key names' );
    ok( eq_set([ map { $_->{public_key} }  @{ $ks->{ssh_keys} } ], [ qw(qsdfsdssddsfsdfs qsdfsdssddsfsdfs2222) ]), $AGENDA.'key public keys' );
    ok( eq_set([ map { $_->{id} }          @{ $ks->{ssh_keys} } ], [ $k->{id}, $k3->{id} ]), $AGENDA.'key ids' );
    ok( eq_set([ map { $_->{fingerprint} } @{ $ks->{ssh_keys} } ], [ $k->{fingerprint}, $k3->{fingerprint} ]), $AGENDA.'key fingerprints' );


#-- delete
    $f = $do->delete_key( $k->{id} );
    isa_ok($f, 'IO::Async::Future', $AGENDA.'future');
    $f->get;
    ok( 1, $AGENDA.'deleted key by id');

    throws_ok {
	$do->delete_key( $k->{id} )->get;
    } qr/not found/, $AGENDA.'non existing key delete';

    throws_ok {
	$do->delete_key( $k2->{fingerprint}.'xxx' )->get;
    } qr/not found/, $AGENDA.'non existing key delete';
    
    $do->delete_key( $k2->{fingerprint} )->get;
    ok( 1, $AGENDA.'deleted key by fingerprint');
    
}

done_testing;

__END__

