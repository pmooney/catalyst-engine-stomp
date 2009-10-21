use strict;
use warnings;
use Test::More tests => 5;

# If an Error in thrown in the code, is it caught and sent back to us
# as a response, or is the 'die' passed through?
#


use FindBin;
use lib "$FindBin::Bin/lib";

BEGIN {
    use_ok 'CatalystX::Test::MessageDriven', 'StompTestApp' or die;
};

eval {
	use JSON;
};
if ($@) {
	plan 'skip_all' => 'JSON not installed, skipping JSON-format test';
    exit;
}

# successful request - type is minimum attributes
my $req = "---\ntype: ping\n";
my $res = request('testcontroller', $req);
ok($res, 'response to ping message');
ok($res->is_success, 'successful response');

# successful request - type will trigger an error object to be thrown
$req = "---\ntype: throwerror\n";
$res = request('testcontroller', $req);
ok($res, 'response to throwerror message');
ok(!$res->is_success, 'unsuccessful response');

my $response;

eval {
    $response = from_json($res->content);
};

ok( ref($response) eq 'StompTestApp::Error', 'successful error thrown');
