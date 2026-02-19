package plugin;

sub _sf_log {
  my (%o) = @_;
  my $msg    = $o{msg}    // '';
  my $debug  = $o{debug}  // 0;
  my $notify = $o{notify} // 0;
  my $client = $o{client};

  return unless $msg ne '';
  return unless $debug || $notify;

  # Always-visible server log line
  quest::we(14, "[SF] $msg");

  # Optional in-game message
  if ($notify && $client) {
	$client->Message(15, "[SF] $msg");
  }
}


use DBI;


our $SF_DBH;
our $SF_DB_HOST   = $ENV{DB_HOST}     // '127.0.0.1';
our $SF_DB_PORT   = $ENV{DB_PORT}     // 3306;
our $SF_DB_NAME   = $ENV{DB_NAME}     // 'peq';
our $SF_DB_USER   = $ENV{DB_USER}     // 'eqemu';
our $SF_DB_PASS   = $ENV{DB_PASSWORD} // '';
our $SF_DBI_EXTRA = $ENV{DBI_EXTRA}   // 'mysql_enable_utf8=1';

our %SF_SETS;
our $SF_CONFIG_LOADED = 0;
our $SETFOCUS_BUCKET_PREFIX = 'setfocus';

sub _sf_dbh {
  return $SF_DBH if $SF_DBH && eval { $SF_DBH->ping };
  my $dsn = "DBI:mysql:database=$SF_DB_NAME;host=$SF_DB_HOST;port=$SF_DB_PORT;$SF_DBI_EXTRA";
  my $ok = eval {
	$SF_DBH = DBI->connect($dsn, $SF_DB_USER, $SF_DB_PASS, { RaiseError=>1, PrintError=>0, AutoCommit=>1 });
	1;
  };
  return ($ok && $SF_DBH) ? $SF_DBH : undef;
}

sub _sf_get_client {
  my ($opt) = @_;
  $opt ||= {};
  return $opt->{client} if $opt->{client};
  return plugin::val('client');
}

sub _sf_load_config {
  my ($force, $debug) = @_;
  return if $SF_CONFIG_LOADED && !$force;

  my $dbh = _sf_dbh();
  %SF_SETS = ();
  $SF_CONFIG_LOADED = 0;
  return unless $dbh;

  my @sets;
  eval {
	my $sth = $dbh->prepare(q{
	  SELECT id, name
	  FROM item_set_focus_sets
	  WHERE enabled = 1
	});
	$sth->execute();
	while (my $r = $sth->fetchrow_hashref) { push @sets, $r; }
	$sth->finish;
	1;
  } or return;

  if (!@sets) { $SF_CONFIG_LOADED = 1; return; }

  my @set_ids = map { int($_->{id}) } @sets;

  my %items_for;
  eval {
	my $in = join(",", ("?") x @set_ids);
	my $sth = $dbh->prepare("SELECT set_id, item_id FROM item_set_focus_items WHERE set_id IN ($in)");
	$sth->execute(@set_ids);
	while (my $r = $sth->fetchrow_hashref) {
	  push @{ $items_for{int($r->{set_id})} }, int($r->{item_id});
	}
	$sth->finish;
	1;
  };

  my %tiers_for;
  eval {
	my $in = join(",", ("?") x @set_ids);
	my $sth = $dbh->prepare(qq{
	  SELECT set_id, pieces_required, spell_id, label, sort_order, id
	  FROM item_set_focus_tiers
	  WHERE set_id IN ($in)
	  ORDER BY pieces_required ASC, sort_order ASC, id ASC
	});
	$sth->execute(@set_ids);
	while (my $r = $sth->fetchrow_hashref) {
	  push @{ $tiers_for{int($r->{set_id})} }, {
		pieces   => int($r->{pieces_required} // 0),
		spell_id => int($r->{spell_id}        // 0),
		label    => ($r->{label}              // ''),
	  };
	}
	$sth->finish;
	1;
  };

  foreach my $s (@sets) {
	my $id = int($s->{id});
	my $items = $items_for{$id} || [];
	my $tiers = $tiers_for{$id} || [];
	next unless @$items && @$tiers;
	$SF_SETS{$id} = { name => ($s->{name} // "Set $id"), items => $items, tiers => $tiers };
  }

  $SF_CONFIG_LOADED = 1;
}

sub _sf_best_tier_for_count {
  my ($tiers, $count) = @_;
  return undef unless $tiers && @$tiers && $count > 0;

  my $best;
  foreach my $t (@$tiers) {
	my $need = int($t->{pieces} // 0);
	next if $need <= 0;
	next if $count < $need;
	$best = $t if !$best || $need > int($best->{pieces} // 0);
  }
  return $best;
}

sub _sf_count_player_pieces {
  my ($client, $items) = @_;
  my %want = map { int($_)=>1 } @$items;
  my $count = 0;
  for my $slot (0..21) {
	my $iid = $client->GetItemIDAt($slot);
	next unless $iid && $iid > 0;
	$count++ if $want{int($iid)};
  }
  return $count;
}

sub _sf_has_buff {
  my ($mob, $spell_id) = @_;
  return 0 unless $mob && $spell_id && $spell_id > 0;

  my $idx;
  eval { $idx = $mob->FindBuff(int($spell_id)); 1; };

  # On some builds FindBuff returns:
  #  - 0 when NOT found (or boolean 0/1)
  #  - >0 when found
  #  - -1 when NOT found (other builds)
  return 0 unless defined $idx;

  # Clear cases
  return 1 if $idx > 0;
  return 0 if $idx < 0;

  # idx == 0 is ambiguous: verify slot 0 really contains this spell (if API exists)
  my $s0;
  my $ok = eval { $s0 = $mob->GetBuffSpellID(0); 1; };
  return ($ok && defined $s0 && int($s0) == int($spell_id)) ? 1 : 0;
}

# ---------------------------------------
# Pet inventory counting (DB-backed)
# ---------------------------------------

sub _sf_count_client_pet_pieces_db {
  my ($charid, $set_id) = @_;
  return 0 unless $charid && $set_id;

  my $dbh = _sf_dbh() or return 0;

  my ($c) = 0;

  eval {
    my $sth = $dbh->prepare(q{
      SELECT COUNT(*)
      FROM character_pet_inventory pi
      JOIN item_set_focus_items si
        ON si.item_id = pi.item_id
      WHERE pi.char_id = ?
        AND si.set_id  = ?
        AND pi.item_id > 0
    });
    $sth->execute(int($charid), int($set_id));
    ($c) = $sth->fetchrow_array();
    $sth->finish;
    1;
  };

  return int($c || 0);
}

# ------------------------------
# Public: client pet tick (pet is independent of owner)
# - counts pet gear from character_pet_inventory (char_id/item_id)
# - re-applies if missing (dispels / duration / zoning)
# ------------------------------
sub set_focus_pet_tick {
  my (%opt) = @_;

  my $pet = $opt{pet} || plugin::val('npc');
  return unless $pet;

  # Only pets
  return unless eval { $pet->IsPet(); 1; } && $pet->IsPet();

  my $owner = eval { $pet->GetOwner(); 1; } ? $pet->GetOwner() : undef;
  return unless $owner;

  # Only CLIENT pets (you said: remove bot pets completely)
  return unless eval { $owner->IsClient(); 1; } && $owner->IsClient();

  my $c = eval { $owner->CastToClient(); 1; } ? $owner->CastToClient() : undef;
  return unless $c;

  my $charid = int($c->CharacterID() || 0);
  return unless $charid > 0;

  _sf_load_config(0, 0);
  return unless %SF_SETS;

  my $pet_eid = int($pet->GetID());

  foreach my $set_id (sort { $a <=> $b } keys %SF_SETS) {
    my $set   = $SF_SETS{$set_id};
    my $tiers = $set->{tiers} || [];

    # tier spell list (for fading)
    my @tier_spells = grep { $_ > 0 } map { int($_->{spell_id} || 0) } @$tiers;

    # count pet pieces from character_pet_inventory
    my $pieces = _sf_count_client_pet_pieces_db($charid, $set_id);

    # pick tier
    my $best = _sf_best_tier_for_count($tiers, int($pieces || 0));
    my $want = $best ? int($best->{spell_id} || 0) : 0;

    # want=0 -> remove any tier buffs from this set (on the pet)
    if ($want <= 0) {
      foreach my $sid (@tier_spells) {
        eval { $pet->BuffFadeBySpellID(int($sid)); 1; };
      }
      next;
    }

    # already has desired buff -> do nothing
    next if _sf_has_buff($pet, $want);

    # remove other tiers (keep want)
    foreach my $sid (@tier_spells) {
      $sid = int($sid);
      next unless $sid > 0;
      next if $sid == $want;
      eval { $pet->BuffFadeBySpellID($sid); 1; };
    }

    # cooldown keyed by PET + set + want (reapplies when dispelled/expired)
    my $cdk = "sf_pet_cd:$pet_eid:$set_id:$want";
    next if quest::get_data($cdk);
    quest::set_data($cdk, 1, 5);

    # cast onto the PET entity id
    eval { quest::castspell($want, $pet_eid); 1; };
  }
}


sub _sf_load_state {
  my ($charid, $set_id) = @_;
  my $key = join(":", $SETFOCUS_BUCKET_PREFIX, int($charid), int($set_id));
  my $raw = quest::get_data($key);
  return undef unless defined $raw && length $raw;

  # stored format: "spell_id=12345;pieces=4"
  my %h;
  for my $pair (split /[;,\n]+/, $raw) {
	my ($k,$v) = split /=/, $pair, 2;
	next unless defined $k;
	$k =~ s/^\s+|\s+$//g;
	next unless length $k;
	$v = '' unless defined $v;
	$v =~ s/^\s+|\s+$//g;
	$h{$k} = $v;
  }

  return undef unless %h;
  return {
	spell_id => int($h{spell_id} || 0),
	pieces   => int($h{pieces}   || 0),
  };
}

sub _sf_save_state {
  my ($charid, $set_id, $state) = @_;
  my $key = join(":", $SETFOCUS_BUCKET_PREFIX, int($charid), int($set_id));

  if ($state) {
	my $spell = int($state->{spell_id} || 0);
	my $pcs   = int($state->{pieces}   || 0);
	my $raw   = "spell_id=$spell;pieces=$pcs";
	quest::set_data($key, $raw, 86400*365);
  } else {
	quest::delete_data($key);
  }
}

# ==========================================================
# Bucket upsert with explicit scope (writes directly to data_buckets)
# ==========================================================
sub _sf_bucket_set_scoped {
  my ($key, $value, $ttl,
	  $account_id, $character_id, $npc_id, $bot_id, $zone_id, $instance_id) = @_;

  my $dbh = _sf_dbh() or return;

  $ttl = int($ttl || 0);
  my $expires = 0;
  if ($ttl > 0) {
	$expires = time() + $ttl;
  }

  $account_id   = int($account_id   || 0);
  $character_id = int($character_id || 0);
  $npc_id       = int($npc_id       || 0);
  $bot_id       = int($bot_id       || 0);
  $zone_id      = int($zone_id      || 0);
  $instance_id  = int($instance_id  || 0);

  # Many EQEmu installs have a UNIQUE key across (key, account_id, character_id, npc_id, bot_id, zone_id, instance_id)
  # REPLACE will overwrite the matching scoped row.
  eval {
	my $sth = $dbh->prepare(q{
	  REPLACE INTO data_buckets
		(`key`, `value`, `expires`, `account_id`, `character_id`, `npc_id`, `bot_id`, `zone_id`, `instance_id`)
	  VALUES
		(?, ?, ?, ?, ?, ?, ?, ?, ?)
	});
	$sth->execute($key, "$value", $expires, $account_id, $character_id, $npc_id, $bot_id, $zone_id, $instance_id);
	$sth->finish;
	1;
  };
}

sub _sf_apply_tier_player {
  my ($client, $set_id, $set_name, $best, $prev) = @_;
  my $prev_spell = $prev ? int($prev->{spell_id} // 0) : 0;
  my $new_spell  = $best ? int($best->{spell_id} // 0) : 0;
  my $new_pieces = $best ? int($best->{pieces}   // 0) : 0;

  if ($prev_spell && (!$new_spell || $new_spell != $prev_spell)) {
	$client->BuffFadeBySpellID($prev_spell);
  }

  if ($new_spell && $new_pieces > 0) {
	if (!_sf_has_buff($client, $new_spell)) {

		  # Prevent timer spam from restarting the cast forever
		  my $cdk = "sf_client_cd:" . int($client->CharacterID()) . ":" . int($set_id) . ":" . int($new_spell);
		  if (!quest::get_data($cdk)) {
			# longer than cast time so it can finish
			quest::set_data($cdk, 1, 8);

			# Cast from quest system (more reliable than repeatedly restarting CastSpell)
			eval { quest::castspell(int($new_spell), int($client->GetID())); 1; };
		  }
		}

	_sf_save_state($client->CharacterID(), $set_id, { spell_id=>$new_spell, pieces=>$new_pieces });
  } else {
	_sf_save_state($client->CharacterID(), $set_id, undef);
  }
}

sub _sf_count_bot_pieces_db {
  my ($bot_id, $set_id, $debug) = @_;
  return 0 unless $bot_id && $set_id;

  my $dbh = _sf_dbh() or return 0;

  my ($c) = 0;

  my $sql = q{
	SELECT COUNT(*) AS pieces
	FROM bot_inventories bi
	JOIN item_set_focus_items si
	  ON si.item_id = bi.item_id
	WHERE bi.bot_id = ?
	  AND si.set_id  = ?
	  AND bi.item_id > 0
  };

  eval {
	my $sth = $dbh->prepare($sql);
	$sth->execute(int($bot_id), int($set_id));
	($c) = $sth->fetchrow_array();
	$sth->finish;
	1;
  } or do {
	my $err = $@ || $DBI::errstr || 'unknown sql error';
	quest::we(14, "[SF] bot piece SQL failed: $err") if $debug;
  };

  return int($c || 0);
}

sub _sf_get_my_bot_ids_db {
  my ($charid) = @_;
  my $dbh = _sf_dbh() or return ();
  my @ids;

  my $sth = $dbh->prepare(q{
	SELECT bot_id
	FROM bot_data
	WHERE owner_id = ?
  });
  $sth->execute(int($charid));
  while (my ($bid) = $sth->fetchrow_array) { push @ids, int($bid); }
  $sth->finish;

  return @ids;
}

# ----------------------------------------------------------
# Write data_buckets with explicit scope (bot_id etc.)
# ----------------------------------------------------------
sub _sf_bucket_replace_scoped {
  my ($key, $value, $ttl, $account_id, $character_id, $npc_id, $bot_id, $zone_id, $instance_id) = @_;

  my $dbh = _sf_dbh() or return 0;

  $ttl = int($ttl || 0);
  my $expires = 0;
  $expires = time() + $ttl if $ttl > 0;

  $account_id   = int($account_id   || 0);
  $character_id = int($character_id || 0);
  $npc_id       = int($npc_id       || 0);
  $bot_id       = int($bot_id       || 0);
  $zone_id      = int($zone_id      || 0);
  $instance_id  = int($instance_id  || 0);

  my $sth = $dbh->prepare(q{
	REPLACE INTO data_buckets
	  (`key`, `value`, `expires`, `account_id`, `character_id`, `npc_id`, `bot_id`, `zone_id`, `instance_id`)
	VALUES
	  (?, ?, ?, ?, ?, ?, ?, ?, ?)
  });
  $sth->execute($key, "$value", $expires, $account_id, $character_id, $npc_id, $bot_id, $zone_id, $instance_id);
  $sth->finish;

  return 1;
}

# ------------------------------
# Public: publisher + player applier
# ------------------------------
sub set_focus_update {
  my (%opt) = @_;

  my $client = _sf_get_client(\%opt);
  return unless $client;

  my $debug  = int($opt{debug}  // 0);
  my $notify = int($opt{notify} // 0);

  
  my $force  = int($opt{force_reload} // 0);
  my $charid = $client->CharacterID();
  return unless $charid;

  _sf_load_config($force, 0);
  if (!%SF_SETS) {
	_sf_log(msg => "no sets loaded (item_set_focus_sets/items/tiers?)", debug => $debug, notify => $notify, client => $client);
	return;
  }

  my @enabled = sort { $a <=> $b } keys %SF_SETS;
  # _sf_bucket_replace_scoped("setfocus_enabled_setids", join(",", @enabled), 86400 * 365, 0, 0, 0, 0, 0, 0);

  # _sf_log(msg => "enabled sets: " . join(",", @enabled), debug => $debug, notify => $notify, client => $client);

  # Publish tier spell lists per set so bots can fade ALL tiers correctly
  foreach my $sid (@enabled) {
	my $tiers = $SF_SETS{$sid}{tiers} || [];
	my %seen;
	my @spells = grep { $_ > 0 && !$seen{$_}++ } map { int($_->{spell_id} // 0) } @$tiers;
	quest::set_data("setfocus_setspells:$sid", join(",", @spells), 86400*365);
  }

  # ----------------
  # player apply
  # ----------------
  foreach my $set_id (keys %SF_SETS) {
	my $set   = $SF_SETS{$set_id};
	my $count = _sf_count_player_pieces($client, $set->{items});
	my $best  = _sf_best_tier_for_count($set->{tiers}, $count);
	my $prev  = _sf_load_state($charid, $set_id);

	my $want_spell = $best ? int($best->{spell_id} // 0) : 0;
	# _sf_log(msg => "player set=$set_id pieces=$count want_spell=$want_spell", debug => $debug, notify => 0, client => $client);

	if ($prev && $best) {
	  my $ps = int($prev->{spell_id} // 0);
	  my $pp = int($prev->{pieces}   // 0);
	  my $ns = int($best->{spell_id} // 0);
	  my $np = int($best->{pieces}   // 0);

	  # If "state matches" but the buff is missing (dispel/expire), DO NOT skip.
	  if ($ps == $ns && $pp == $np) {
		next if _sf_has_buff($client, $ns);
	  }
	} elsif (!$prev && !$best) {
	  next;
	}


	_sf_apply_tier_player($client, $set_id, $set->{name}, $best, $prev);
	
	}


  # ----------------
  # bot publish
  # ----------------
  my @bot_ids = _sf_get_my_bot_ids_db($charid);
  # _sf_log(msg => "found bots: " . scalar(@bot_ids) . " ids=[" . join(",", @bot_ids) . "]", debug => $debug, notify => $notify, client => $client);

  foreach my $bid (@bot_ids) {
	foreach my $set_id (keys %SF_SETS) {
	  my $count = _sf_count_bot_pieces_db($bid, $set_id, $debug);
	  my $best  = _sf_best_tier_for_count($SF_SETS{$set_id}{tiers}, $count);
	  my $want  = $best ? int($best->{spell_id} // 0) : 0;
	# quest::we(14, "[SF] bot=$bot_id set=$set_id pieces=$pieces want=$want");
	  # _sf_log(msg => "PUBLISH bot=$bid set=$set_id pieces=$count want_spell=$want", debug => $debug, notify => 0, client => $client);

	  # _sf_bucket_replace_scoped("setfocus_botspell:$bid:$set_id", $want, 86400 * 365, 0, 0, 0, $bid, 0, 0);
	}
  }
}

# ------------------------------
# Public: bot tick (called from global_bot.pl)
# ------------------------------
sub set_focus_bot_tick {
  # quest::we(14, "[SF] bot_tick fired");

  my (%opt) = @_;

  my $actor = $opt{actor};
  return unless $actor;

  my $bot_id = 0;
  eval { $bot_id = int($actor->GetBotID() || 0); 1; };
  return unless $bot_id > 0;

  # load config (sets/tiers/items)
  _sf_load_config(0, 0);
  # quest::we(14, "[SF] bot_tick bot_id=$bot_id sets_loaded=" . scalar(keys %SF_SETS));

  return unless %SF_SETS;

  my $dbh = _sf_dbh() or return;

  foreach my $set_id (sort { $a <=> $b } keys %SF_SETS) {
	my $set   = $SF_SETS{$set_id};
	my $tiers = $set->{tiers} || [];

	# tier spell list (for fading)
	my @tier_spells = grep { $_ > 0 } map { int($_->{spell_id} || 0) } @$tiers;

	# count pieces ANYWHERE in bot_inventories (no slot filtering)
	my $pieces = 0;
	eval {
	  my $sth = $dbh->prepare(q{
		SELECT COUNT(*)
		FROM bot_inventories bi
		JOIN item_set_focus_items si
		  ON si.item_id = bi.item_id
		WHERE bi.bot_id = ?
		  AND si.set_id  = ?
		  AND bi.item_id > 0
	  });
	  $sth->execute(int($bot_id), int($set_id));
	  ($pieces) = $sth->fetchrow_array();
	  $sth->finish;
	  1;
	};

	# pick tier
	my $best = _sf_best_tier_for_count($tiers, int($pieces || 0));
	my $want = $best ? int($best->{spell_id} || 0) : 0;
	# quest::we(14, "[SF] bot_id=$bot_id set=$set_id pieces=$pieces want=$want");
	


	# want=0 -> remove any tier buffs from this set
	if ($want <= 0) {
	  foreach my $sid (@tier_spells) {
		eval { $actor->BuffFadeBySpellID($sid); 1; };
	  }
	  next;
	}

	# already has desired buff -> do nothing
	my $has = _sf_has_buff($actor, $want);
	# quest::we(14, "[SF] has_check bot_id=$bot_id set=$set_id want=$want has=$has");
	next if $has;


	# remove other tier buffs (keep want)
	foreach my $sid (@tier_spells) {
	  next if $sid == $want;
	  eval { $actor->BuffFadeBySpellID($sid); 1; };
	}

	# cooldown keyed by WANT so changes/dispels reapply quickly
	my $cdk = "sf_cd:$bot_id:$set_id:$want";
	next if quest::get_data($cdk);
	quest::set_data($cdk, 1, 5);

	# quest::we(14, "[SF] BOTCAST bot_id=$bot_id set=$set_id pieces=$pieces want=$want");
	eval { quest::castspell($want, $actor->GetID()); 1; };
  }
}



1;
