=head1 NAME

Bot::BasicBot::Pluggable::Module::Infobot

=head1 SYNOPSIS

Does infobot things - basically remmebers and returns factoids. Will ask
another infobot about factoids that it doesn't know about, if you want.

=head1 IRC USAGE

Assume the bot is called 'eric'. Then you'd use the infobot as follows.

  me: eric, water is wet.
  eric: Ok, water is wet.
  me: water?
  eric: water is wet.
  me: eric, water is also blue.
  eric: ok, water is also blue.
  me: eric, water?
  eric: water is wet or blue.
  
etc, etc.

a response that begins <reply> will have the '<noun> is' stripped, so

  me: eric, what happen is <reply>somebody set us up the bomb
  eric: ok, what happen is <reply>somebody set us up the bomb.
  me: what happen?
  eric: somebody set us up the bomb

just don't do that in #london.pm.

Likewise, a response that begins <action> will be emoted as a response,
instead of said. Putting '|' characters in the reply indicates different
possible answers, and the bot will pick one at random.

  me: eric, dice is one|two|three|four|five|six
  eric: ok, dice is one|two|three|four|five|six
  me: eric, dice?
  eric: two.
  me: eric, dice?
  eric: four.
  
Finally, you can read RSS feeds:

  me: eric, jerakeen.org is <rss="http://jerakeen.org/index.rdf">
  eric: ok, jerakeen.org is...
  
ok, you get the idea.

You can also tell the bot to learn a factoid from another bot, as follows:

  me: eric, learn fact from dispy
  eric: learnt 'fact is very boring' from dipsy.
  me: fact?
  eric: fact is very boring
  
=head1 VARS

=over 4

=item ask

Set this to the nick of an infobot and your bot will ask them about factoids
that we don't know about, and forward them on (with attribution).

=back

=head2 TODO

If we need to request an RSS feed that takes a long time to come back, we'll
time out and drop off the server. oops.


=cut

package Bot::BasicBot::Pluggable::Module::Infobot;
use Bot::BasicBot::Pluggable::Module;
use base qw(Bot::BasicBot::Pluggable::Module);

use XML::RSS;
use LWP::Simple ();
use strict;
use warnings;

sub init {
  my $self = shift;

  # set lots of user vars if they're not already set, so that they
  # show up for users of the Vars module.
  for (qw( ask passive_ask passive_learn stopwords )) {
    $self->set("user_$_" => "") unless defined($self->get("user_$_"));
  }
  
  # some vague plan to allow DB version upgrades
  $self->set("db_version" => "1") unless $self->get("db_version");

  # hash to record the queries we've asked of other infobots
  $self->{remote_infobot} = {};
}

sub help {
  return "ooooooh, infobots. They're hard. ".
  "See http://search.cpan.org/perldoc?Bot::BasicBot::Pluggable::Module::Infobot";
}

sub told {
  my ($self, $mess) = @_;
  my $body = $mess->{body};

  # looks like an infobot reply
  if ($body =~ s/^:INFOBOT:REPLY (\S+) (.*)$//) {
    return $self->infobot_reply($1, $2, $mess);
  }

  # these are all direct commands, and must be addressed.

  return unless $mess->{address};
  
  if ($body =~ /^forget\s+(.*)$/i) {
    if ($self->delete_factoid($mess->{who}, $1)) {
      return "I forgot about $1";
    } else {
      return "I don't know anything about $1";
    }
  }

  if ($body =~ /^ask\s+(\S+)\s+about\s+(.*)$/i) {
    $self->ask_factoid($2, $1, $mess);
    return "asking $1 about $2..\n";
  }

  if ($body =~ /^search\s+for\s+(.*)$/i) {
    return "privmsg only, please" unless $mess->{channel} eq "msg";
    my @results = $self->search_factoid(split(/\s+/, $1)) or return;
    $#results = 20 if $#results > 20;
    return "Keys: ".join(", ", map { "'$_'" } @results);
  }

}

sub fallback {
  my ($self, $mess) = @_;
  my $body = $mess->{body};

  # fallback - passively learn things and answer questions.
  
  if ( $body =~ s/\?+$// and ( $mess->{address} or $self->get("user_passive_ask") ) ) {
    # literal question?
    my $literal = 1 if ($body =~ s/^literal\s+//i);

    # get the factoid, and the type of relationship
    my ($is_are, $factoid) = $self->get_factoid($body, $literal);

    # if there's no such factoid, we give up.
    unless ($factoid) {
      return $mess->{address} ? "No clue. Sorry." : undef;
    }

    # emote?
    if ($factoid =~ s/^<action>\s*//i) {
      $self->bot->emote({
        who => $mess->{who},
        channel => $mess->{channel},
        body => $factoid
      });
      return 1;
    }

    # a straight reply
    if ($factoid =~ s/^<reply>\s*//i) {
      return $factoid;
    }

    # normal factoid
    return "$body $is_are $factoid";

  }

  # the only thing left is learning factoids. are we addressed? Or
  # are we willing to learn passively?
  return unless ( $mess->{address} or $self->get("user_passive_learn") );

  # does it even look like a factoid?
  return unless ($body =~ /^(.*?)\s+(is)\s+(.*)$/i or $body =~ /^(.*?)\s+(are)\s+(.*)$/i);

  my ($object, $is_are, $description) = ($1, $2, $3);

  # allow corrections and additions.
  my $replace = 1 if ($object =~ s/no,?\s*//i);
  my $also = 1 if ($description =~ s/^also\s+//i);

  # long factoid keys are almost _always_ wrong.
  # TODO - this should be a user variable
  return if length($object) > 25;

  # certain words can't ever be factoid keys, to prevent insanity.
  my @stopwords = split(/\s*,?\s*/, $self->get("user_stopwords") || "");
  return if grep(/^\Q$object$/i, @stopwords);

  # if we're replacing things, remove it first.
  if ($replace) {
    $self->delete_factoid($object);
  }

  # get any current factoid there might be.
  my (undef, $current) = $self->get_factoid($object);
  
  # we cna't add without explicit instruction.
  if ($current and !$also) {
    return "But I already know something about $object";
  }

  $self->add_factoid($object, $is_are, split(/\s+or\s+/, $description);

  # return an ack if we were addressed only
  return $mess->{address} ? "ok" : 1;
}

sub get_factoid {
  my ($self, $object, $literal) = @_;
  my $raw = $self->get( "infobot_".lc($object) )
    or return;

  my ($is_are, @factoids) = split(/\t/, $raw);

  my @simple;
  my @alternatives;
  for (@factoids) {
    if (s/^\|//) {
      push @alternatives, $_;
    } else {
      push @simple, $_;
    }
  }
  unshift @alternatives, join(" or ", @simple);

  return ("=${is_are}=", join (" =or= ", @alternatives)) if $literal;

  my $factoid = $alternatives[ rand(@alternatives) ];
  $factoid =~ s/<rss\s*=\s*\"?([^>\"]+)\"?>/$self->parseRSS($1)/ieg;

  return ($is_are, $factoid);
}

sub ask_factoid {
  my ($self, $object, $ask, $mess) = @_;

  # unique ID to reference this in future
  my $id = "<" . int(rand(100000)) . ">";
  
  # store the message, so we can reply in context later
  $self->{remote_infobot}{$id} = $mess;

  # ask, using an infobot protocol, the thing we've been told to ask.
  # this will hopefully result in a reply coming back later.
  $self->bot->say(
    who => $ask,
    channel=>'msg',
    body=>":INFOBOT:QUERY $id $object"
  );
}

sub search_factoid {
  my ($self, @terms) = @_;
  my @keys = map { s/^infobot_// ? $_ : () } $self->store_keys;
  for my $term (@terms) {
    @keys = grep { /\Q$term/ } @keys;
  }
  return @keys;
}

sub add_factoid {
  my ($self, $object, $is_are, @factoids) = @_;
  
  # we're splitting on tabs, so we can't store them. Last-ditch
  # safety measure.
  s/\t+//g for @factoids;
  
  my $raw = $self->get( "infobot_".lc($object) ) || "$is_are";
  $raw .= "\t$_" for @factoids;

  $self->set( "infobot_".lc($object) , $raw );  return 1;
}

sub delete_factoid {
  my ($self, $object) = @_;
  $self->unset( "infobot_".lc($object) );
  return 1;
}

sub parseRSS {
    my ($self, $url) = @_;

    my $items;
    eval {
        my $rss = new XML::RSS;
        $rss->parse(LWP::Simple::get($url));
        $items = $rss->{items};
    };

    return "<< Error parsing RSS from $url: $@ >>" if $@;
    my $ret;
    foreach my $item (@$items) {
        my $title = $item->{title};
        $title =~ s/\s+/ /;
        $title =~ s/\n//g;
        $title =~ s/\s+$//;
        $title =~ s/^\s+//;
        $ret .= "$item->{'title'}; ";
    }
    return $ret;
}

# We've been replied to by an infobot.
sub infobot_reply {
  my ($self, $id, $return, $mess) = @_;

  # get the message that caused the ask initially, so we can reply to it
  # if there wasn't one, just give up.
  my $infobot_data = $self->{remote_infobot}{$id} or return 1;

  # this is the string that the other infobot returned to us.
  my ($object, $db, $factoid) = ($return =~ /^(.*) =(\w+)=> (.*)$/);

  $self->set_factoid($mess->{who}, $object, $db, $factoid);

  # reply to the original request saying 'we got it'
  $self->bot->say(
    channel => $infobot_data->{channel},
    who     => $infobot_data->{who},
    body    => "Learnt about $object from $mess->{who}",
  );

  return 1;

}

1;
