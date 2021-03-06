package perlcassa::Decoder;

use strict;
use warnings;
use base 'Exporter';
our @EXPORT = qw(make_cql3_decoder pack_val unpack_val);

use Encode;
use Math::BigInt;
use Math::BigFloat;
use Socket qw(AF_INET);
use Socket6 qw(inet_ntop AF_INET6);

use Cassandra::Cassandra;
use Cassandra::Constants;
use Cassandra::Types;

# XXX this is yanked from perlcassa.pm. it should only be in one place
# hash that contains pack templates for ValidationTypes
our %simple_packs = (
	'org.apache.cassandra.db.marshal.AsciiType' 		=> 'A*',
	'org.apache.cassandra.db.marshal.BooleanType' 		=> 'C',
	'org.apache.cassandra.db.marshal.BytesType' 		=> 'a*',
	'org.apache.cassandra.db.marshal.DateType' 		=> 'q>',
	'org.apache.cassandra.db.marshal.FloatType' 		=> 'f>',
	'org.apache.cassandra.db.marshal.DoubleType' 		=> 'd>',
	'org.apache.cassandra.db.marshal.Int32Type' 		=> 'l>',
	'org.apache.cassandra.db.marshal.LongType' 		=> 'q>',
	'org.apache.cassandra.db.marshal.CounterColumnType'	=> 'q>',
	'org.apache.cassandra.db.marshal.TimestampType'		=> 'q>',
	'ascii'							=> 'A*',
	'varchar'						=> 'A*',
	'boolean'						=> 'C',
	'blob'							=> 'a*',
	'counter'						=> 'q>',
	'double'						=> 'd>',
	'float'							=> 'f>',
	'text'							=> 'a*'
);

our %complicated_unpack = (
	'org.apache.cassandra.db.marshal.IntegerType'		=> \&unpack_IntegerType,
	'org.apache.cassandra.db.marshal.DecimalType'		=> \&unpack_DecimalType,
	'org.apache.cassandra.db.marshal.InetAddressType'	=> \&unpack_ipaddress,
	'org.apache.cassandra.db.marshal.UUIDType'		=> \&unpack_uuid,
	'org.apache.cassandra.db.marshal.TimeUUIDType'		=> \&unpack_uuid,
	'org.apache.cassandra.db.marshal.UTF8Type'		=> \&unpack_UTF8,
	'bigint'						=> \&unpack_IntegerType,
	'decimal'						=> \&unpack_DecimalType,
	'int'							=> \&unpack_IntegerType,
	'uuid'							=> \&unpack_uuid,
	'timeuuid'						=> \&unpack_uuid,
	'varint'						=> \&unpack_IntegerType,
	'inet'							=> \&unpack_ipaddress
);

our %complicated_pack = (
	'org.apache.cassandra.db.marshal.IntegerType'		=> \&pack_IntegerType,
	'org.apache.cassandra.db.marshal.DecimalType'		=> \&pack_DecimalType,
	'org.apache.cassandra.db.marshal.InetAddressType'	=> \&pack_ipaddress,
	'org.apache.cassandra.db.marshal.UUIDType'		=> \&pack_uuid,
	'org.apache.cassandra.db.marshal.TimeUUIDType'		=> \&pack_uuid,
	'org.apache.cassandra.db.marshal.UTF8Type' 		=> \&pack_UTF8,
);

sub new {
	my ($class, %opt) = @_;

	bless my $self = {
	        metadata => undef,
		debug => 0,
	}, $class;
}

##
# Used to create CQL3 column decoder
# 
# Arguments:
#   schema - the Cassandra::CqlMetadata containing the schema
# 
# Returns:
#   A decoder object that can decode/deserialize Cassandra::Columns
##
sub make_cql3_decoder {
    my $schema = shift;
    my $decoder = perlcassa::Decoder->new();
    $decoder->{metadata} = $schema;
    return $decoder;
}

##
# Used to decode a CQL row.
# 
# Arguments:
#   row - a Cassandra::CqlRow
#
# Returns:
#   An hash of hashes, each hash containing the column values
##
sub decode_row {
    my $self = shift;
    my $packed_row = shift;
    my %row;
    for my $column (@{$packed_row->{columns}}) {
        $row{$column->{name}} = $self->decode_column($column);
    }
    return %row;
}

##
# Used to decode a CQL column.
#
# Arguments:
#   column - a Cassandra::Column
# Returns:
#   a hash containing the unpacked column data.
##
sub decode_column {
    my $self = shift;
    my $column = shift;

    my $packed_value = $column->{value};
    my $column_name = $column->{name} || undef;
    my $data_type = $self->{metadata}->{default_value_type};
    if (defined($column_name)) {
        $data_type = $self->{metadata}->{value_types}->{$column_name};
    }
    my $value = undef;
    if (defined($column->{value})) {
        $value = unpack_val($packed_value, $data_type),
    }
    if (defined($column->{ttl}) || defined($column->{timestamp})) {
        # The ttl and timestamp Cassandra::Column values are not
        # defined when using CQL3 calls
        die("[BUG] Cassandra returned a ttl or timestamp with a CQL3 column.");
    }
    return $value;
}

##
# Used to unpack values based on a pased in data type. This call will die if
# the data type is unknown.
# 
# Arguments:
#   packed_value - the packed value to unpack
#   data_type - the data type to use to unpack the value
#
# Return:
#   An unpacked value
##
sub unpack_val {
    my ($packed_value, $data_type) = @_;

    if (Encode::is_utf8($packed_value)) {
        # We should not be getting utf8 strings... they should be byte strings
        # something is odd with the thrift decoding stuff
        #warn("[BUG] Found utf8 string in unpack, converting.");
        Encode::_utf8_off($packed_value);
    }

    my $unpacked;
    if (defined($simple_packs{$data_type})) {
        $unpacked = unpack($simple_packs{$data_type}, $packed_value);
    } elsif ($data_type =~ /^org\.apache\.cassandra\.db\.marshal\.(Map|List|Set)Type/) {
        # Need to unpack a collection of values
        $unpacked = unpack_collection($packed_value, $data_type);
    } elsif (defined($complicated_unpack{$data_type})) {
        # It is a complicated type
        my $unpack_sub = $complicated_unpack{$data_type};
        $unpacked = $unpack_sub->($packed_value);
    } else {
        die("[ERROR] Attempted to unpack unimplemented data type. ($data_type)");
    }
    return $unpacked;
}

sub pack_val {
    my $value = shift;
    my $data_type = shift;

    my $packed;
    if (defined($simple_packs{$data_type})) {
        $packed = pack($simple_packs{$data_type}, $value);
    } elsif ($data_type =~ /(List|Map|Set)Type/) {
        # Need to pack the collection
        $packed = pack_collection($value, $data_type);
    } elsif (defined($complicated_pack{$data_type})) {
        # It is a complicated type
        my $pack_sub = $complicated_pack{$data_type};
        $packed = $pack_sub->($value);
    } else {
        die("[ERROR] Attempted to pack an unknown data type. ($data_type)");
    }

    return $packed;
}

# Convert a hex string to a signed bigint
sub hex_to_bigint {
    my $sign = shift;
    my $hex = shift;
    my $ret;
    if ($sign) {
        # Flip the bits... Then flip again... 
        # I think Math::BigInt->bnot() is broken
        $hex =~ tr/0123456789abcdef/fedcba9876543210/;
        $ret = Math::BigInt->new("0x".$hex)->bnot();
    } else {
        $ret = Math::BigInt->new("0x".$hex);
    }
    return $ret;
}

# Convert a signed bigint to a packed value
sub bigint_to_pack {
    my $value = shift;
    my $hex;
    my $align;
    if ($value->sign() eq '-') {
        $hex = $value->binc()->as_hex();
        $hex =~ s/^-0x//;
        # Need to flip the bits, bnot does something funky
        $hex =~ tr/0123456789abcdef/fedcba9876543210/;
        $align = "f";
    } else {
        $hex = $value->as_hex();
        $hex =~ s/^0x//;
        if ($hex =~ /^[89abcdef]/) { 
            # if the highest bit is set, and this is not supposed to be
            # negative then we need some padding.
            $hex = "0".$hex;
        }
        $align = "0";
    }
    if (length($hex)%2 == 1) {
        # Things need to be aligned to even length
        $hex = $align . $hex;
    }
    my $encoded = pack("H*", $hex);
    return $encoded;
}

# Unpack arbitrary precision int
# Returns a Math::BigInt
sub unpack_IntegerType {
    my $packed_value = shift;
    my $data_type = shift;

    if(!defined($packed_value)) {
	return undef;
    }

    my $ret = hex_to_bigint(unpack("B1XH*", $packed_value));
    my $unpacked_int = $ret->bstr();
    return $unpacked_int;
}

# XXX
sub pack_IntegerType {
    my $value = shift;

    # if it is not a ref, assume it is a string
    # if its a ref, assume its a Math::BigInt
    unless (ref($value)) {
        $value = Math::BigInt->new($value);
    }

    my $encoded = bigint_to_pack($value);
    return $encoded;
}

# Unpack arbitrary precision decimal
# Returns a Math::BigFloat
sub unpack_DecimalType {
    my $packed_value = shift;
    my $data_type = shift;
    my ($exp, $sign, $hex) = unpack("NB1XH*", $packed_value);
    my $mantissa = hex_to_bigint($sign, $hex);
    my $ret = Math::BigFloat->new($mantissa."E-".$exp);
    my $unpacked_dec = $ret->bstr();
    return $unpacked_dec;
}

# Unpack arbitrary precision deciaml
# Expects the first argument to be a string or a Math::BigFloat
# Returns a packed value
sub pack_DecimalType {
    my $value = shift;

    # TODO Check for passed in bigfloat
    unless (ref($value)) {
        $value = Math::BigFloat->new($value);
    }

    my ($mantissa, $exponent) = $value->parts();
    
    ### XXX
    # Numbers with positive exponents do not get packed correctly
    my $exp = $exponent->babs();
    ### XXX

    my $encoded = pack("N a*", $exp, bigint_to_pack($mantissa));

    # print "unpack encoded: ".unpack("H*", $encoded)."\n";
    return $encoded;
}

# Unpack inet type
# Returns a string
sub unpack_ipaddress {
    my $packed_value = shift;
    my $data_type = shift;
    my $len = length($packed_value);
    my $ret;
    if ($len == 16) {
        # Unpack ipv6 address
        $ret = inet_ntop(AF_INET6, $packed_value);
    } elsif ($len == 4) {
        $ret = inet_ntop(Socket::AF_INET(), $packed_value);
    } else {
        die("[ERROR] Invalid inet type.");
    }
    return $ret;
}

# Unpack uuid/uuidtime type
# Returns a string
sub unpack_uuid {
    my $packed_value = shift;
    my $data_type = shift;
    my $len = length($packed_value);
    my @values;
    if ($len ==16) {
        @values = unpack("H8 H4 H4 H4 H12", $packed_value);
    } else {
        die("[ERROR] Invalid uuid type.");
    }
    return join("-", @values);
}

# Takes a string uuid and returns the packed version for CQL3
sub pack_uuid {
    my $value = shift;
    my @values = split(/-/, $value);
    my $encoded = pack("H8 H4 H4 H4 H12", @values);
    return $encoded;
}


# Takes a string and packs it
# TODO more testing
sub pack_UTF8 {
    # I think it is this simple...
    return Encode::encode_utf8($_[0]);
}

# Takes utf8 bytes and returns a utf8 string
sub unpack_UTF8 {
    return decode_utf8($_[0]);
}


# Unpack a collection type. List, Map, or Set
# Returns:
#   array - for list
#   array - for set
#   hash - for map
#
sub unpack_collection {
    my $packed_value = shift;
    my $data_type = shift;
    my $unpacked;
    my ($base_type, $inner_type) = ($data_type =~ /^([^)]*)\(([^)]*)\)/);

    # "nX2n/( ... )"
    # Note: the preceeding is the basic template for collections.
    # The template code grabs a 16-bit unsigned value, which is the number of
    # items/pairs in the collection. Then it goes backward 2 bytes (16 bits)
    # and grabs 16-bit value again, but uses it to know how many items/pairs
    # to decode
    if ($base_type =~ /org\.apache\.cassandra\.db\.marshal\.(List|Set)Type/) {
        # Handle the list and set. They are bascally the same
        # Each item is unpacked as raw bytes, then unpacked by our normal
        # routine
        my ($count, @values) = unpack("nX2n/(n/a)", $packed_value);
        $unpacked = [];
        for (my $i = 0; $i < $count; $i++) {
            my $v = unpack_val($values[$i], $inner_type);
            push(@{$unpacked}, $v);
        }

    } elsif ($base_type eq "org.apache.cassandra.db.marshal.MapType") {
        # Handle the map types
        # Each pair is unpacked as two groups of raw bytes, then unpacked by
        # our normal routines
        my ($count, @values) = unpack("nX2n/(n/a n/a)", $packed_value);
        my @inner_types = split(",", $inner_type);
        $unpacked = {};
        for (my $i = 0; $i < $count; $i++) {
            my $k = unpack_val($values[($i*2+0)], $inner_types[0]);
            my $v = unpack_val($values[($i*2+1)], $inner_types[1]);
            $unpacked->{$k} = $v;
        }

    } else {
        die("[BUG] You broke it. File a bug... What is '$data_type'?");
    }
    return $unpacked;
}


# Pack a collection type. List, Map, or Set
# Expectations...
#   For List and Set types the first arugment is expected to be an array.
#
#   For Map types... ? not implemented XXX
#
# Returns the packed stuff #XXX better comment
sub pack_collection {
    my $values = shift;
    my $data_type = shift;
    my $packed;
    my ($base_type, $inner_type) = ($data_type =~ /^([^)]*)\(([^)]*)\)/);

    # "n/( ... )"
    # Note: the preceeding is the basic template for collections.
    # The template code puts a 16-bit unsigned value, which is the number of
    # items/pairs in the collection.
    if ($base_type =~ /org\.apache\.cassandra\.db\.marshal\.(List|Set)Type/) {
        # Handle the list and set. They are bascally the same.
        # Pack each value as inner type
        my @packed_values = map { pack_val($_, $inner_type) } @$values;
        # Pack them all together. First count of elements, then each element
        # is preceded by its length in bytes
        my $encoded = pack("n/(n/a)", @packed_values);
        $packed = $encoded;
    } elsif ($base_type eq "org.apache.cassandra.db.marshal.MapType") {
        die("[BUG] XXX Unable to pack map types.\n");
        ## Handle the map types
        ## Each pair is unpacked as two groups of raw bytes, then unpacked by
        ## our normal routines
        #my ($count, @values) = unpack("nX2n/(n/a n/a)", $values);
        #my @inner_types = split(",", $inner_type);
        #$unpacked = {};
        #for (my $i = 0; $i < $count; $i++) {
        #    my $k = unpack_val($values[($i*2+0)], $inner_types[0]);
        #    my $v = unpack_val($values[($i*2+1)], $inner_types[1]);
        #    $unpacked->{$k} = $v;
        #}

    } else {
        die("[BUG] You broke it. File a bug... What is '$data_type'?");
    }
    return $packed;
}

1;
