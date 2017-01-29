# TODO: pod

package AnyEvent::YWeather;

use warnings;
use strict;

use AnyEvent::HTTP;
use URI;
use JSON;
use DateTime;

use base Exporter::;

our @EXPORT = qw(yweather_get);

our $VERSION = 0.01;

# Yahoo! Weather API: http://developer.yahoo.com/weather/



# inlined: sub DEBUG(){1 or 0} based on ENV:
BEGIN {
	no strict 'refs';
	*DEBUG = $ENV{ANYEVENT_YWEATHER_DEBUG} ? sub(){1} : sub(){0};
}
sub DPRINT { DEBUG && print STDERR $_[0]."\n"; }

use Data::Dumper;

sub F_to_C($) {
	my( $F )= @_;

	defined $F
		or return;

	return int( ( $F-32 )*5/9 +0.5 );
}

sub inHg_to_hPa($) {
	my( $inHg )= @_;

	defined $inHg
		or return;

	return int( $inHg/33.86390 +0.5);
}

sub miles_to_km($) {
	my( $miles )= @_;

	defined $miles
		or return;

	return int( 1.609347219*$miles +0.5);
}

### "Fri, 13 Nov 2015 8:00 am CET"
our $re_date = qr/^\s*\w{3},
	\s+(\d{1,2})
	\s+(\w{3})
	\s+(\d{4})
	\s+(\d{1,2})
		:(\d{2})
	\s+(\w{2})
	\s+(\w{3,4})
	\s*$/x;

our %monthindex;
{
	my $i = 1;

	%monthindex = map {
		$_ => $i++;
	}  qw/Jan Feb Mar Apr May Jun Jul Aug Sep Oct Nov Dec/;
}

sub date_to_epoch($) {
	my( $value )= @_;

	defined $value
		or return;

	$value =~ /$re_date/
		or return;

	my( $d, $mon, $y, $h, $n, $p, $tz ) = ( $1,$2,$3,$4,$5,$6,$7 );

	# 12 AM= 0, 12 PM= 12
	$h+=12 if( $h==12 );
	if( $p eq "PM" ){
		$h = ($h+12) % 24
	} else {
		$h %= 12;
	}

	my $m = $monthindex{$mon};
	defined $m
		or return;

	my $dt = eval { DateTime->new(
             year       => $y,
             month      => $m,
             day        => $d,
             hour       => $h,
             minute     => $n,
             time_zone  => $tz,
	) } or return;

	return $dt->epoch;
}

sub extract {
	my( $j ) = @_;

	my $data = $j->{query}{results}{channel}
		or return;
	my $item= $data->{item}
		or return;

	$item->{pubDateEpoch} = date_to_epoch( $item->{pubDate} );

	$data->{wind}{chill} = F_to_C( $data->{wind}{chill}  ); # wrongly always °F
	$data->{atmosphere}{pressure} = inHg_to_hPa( $data->{atmosphere}{pressure} ); # wrongly always in inHg

	my $units= $data->{units};

	if( $units->{temperature} ne 'C' ){
		$item->{condition}{temp} = F_to_C( $item->{condition}{temp} );

		foreach my $fc ( @{$item->{forecast}} ){
			$fc->{low} = F_to_C( $fc->{low} );
			$fc->{high} = F_to_C( $fc->{high} );
		}

	}

	if( $units->{speed} ne 'km/h' ){
		$data->{wind}{speed} = miles_to_km( $data->{wind}{speed} );
	}

	if( $units->{distance} ne 'km' ){
		$data->{atmosphere}{visibility} = miles_to_km( $data->{atmosphere}{visibility} );
	}

	return $data;
}

our $re_ok = qr/^2/;

# timeout => seconds
# cb => coderef( $data, $error ) 
sub yweather_get {
	my( $woid, %a ) = @_;

	my $uri = "https://query.yahooapis.com/v1/public/yql"
		."?q=select%20*%20from%20weather.forecast%20where%20woeid=$woid%20and%20u=%27c%27"
		."&format=json"
		."&env=store%3A%2F%2Fdatatables.org%2Falltableswithkeys";

	http_post $uri, "",
		headers	=> {
			'User-Agent'	=> 'AnyEvent::YWeather',
			'Accept'	=> 'application/json',
			"Accept-Charset"	=> "utf-8",
		},
		timeout	=> $a{timeout}||30,
		persistent => 0,
	sub {
		return unless $a{cb};

		my( $b, $h ) = @_;

		my( $e, $data );

		if( $h->{Status} !~ /$re_ok/ ){
			$e = "bad status $h->{Status} $h->{Reason}";

		} else {
			my $j = eval { decode_json $b };
			DEBUG && DPRINT "response: ". Dumper( $j );

			if( my $err = $@ ){
				$e = "decode failed: $err";

			} elsif( ! $j->{query}{count} ){
				$e = 'no results retrieved';

			} elsif( $j->{query}{count} != 1 ){
				$e = "expected one result, got ".
					$j->{query}{count} ." results";

			} else {
				$data = extract( $j );
			}
		}
		$a{cb}->( $data, $e );
	};
}


1;
