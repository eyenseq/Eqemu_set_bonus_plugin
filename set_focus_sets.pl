package plugin;

use DBI;
use JSON::PP qw(encode_json decode_json);

# ==========================================================
# Set Focus Effects Plugin (DB-driven)
#
#  - DB tables:
#      item_set_focus_sets
#      item_set_focus_items
#      item_set_focus_tiers
#
#  - For each enabled set, counts equipped pieces on the client.
#  - Picks the HIGHEST tier whose pieces_required <= equipped_count.
#  - Applies that tier's spell as a buff.
#  - Removes / upgrades buffs when gear changes.
#  - Remembers per-character current tier in data_buckets.
#
# Public entry:
#   plugin::set_focus_update(%opts);
#
# Call from:
#   EVENT_ENTERZONE, EVENT_EQUIP_ITEM, EVENT_UNEQUIP_ITEM, etc.
#
# Example:
#   sub EVENT_ENTERZONE   { plugin::set_focus_update(); }
#   sub EVENT_EQUIP_ITEM  { plugin::set_focus_update(); }
#   sub EVENT_UNEQUIP_ITEM{ plugin::set_focus_update(); }
#
# Options:
#   client       => $client   # optional, default plugin::val('client')
#   debug        => 1         # enable extra quest::debug()
#   force_reload => 1         # reloads DB config on this call
#
# Env vars (same pattern as your other plugins):
#   DB_HOST, DB_PORT, DB_NAME, DB_USER, DB_PASSWORD, DBI_EXTRA
# ==========================================================

# --------------- DB CONFIG ---------------

our $SF_DBH;
our $SF_DB_HOST = $ENV{DB_HOST}     // '127.0.0.1';
our $SF_DB_PORT = $ENV{DB_PORT}     // 3306;
our $SF_DB_NAME = $ENV{DB_NAME}     // 'peq';
our $SF_DB_USER = $ENV{DB_USER}     // 'eqemu';
our $SF_DB_PASS = $ENV{DB_PASSWORD} // '';
our $SF_DBI_EXTRA = $ENV{DBI_EXTRA} // 'mysql_enable_utf8=1';

# --------------- CACHES ------------------

our %SF_SETS;
our $SF_CONFIG_LOADED = 0;

# Bucket prefix: setfocus:<charid>:<set_id>
our $SETFOCUS_BUCKET_PREFIX = 'setfocus';

# ==========================================================
# Internal: DB handle
# ==========================================================
sub _sf_dbh {
    return $SF_DBH if $SF_DBH && eval { $SF_DBH->ping };
    my $dsn = "DBI:mysql:database=$SF_DB_NAME;host=$SF_DB_HOST;port=$SF_DB_PORT;$SF_DBI_EXTRA";

    my $ok = eval {
        $SF_DBH = DBI->connect(
            $dsn, $SF_DB_USER, $SF_DB_PASS,
            { RaiseError => 1, PrintError => 0, AutoCommit => 1 }
        );
    };
    if (!$ok || !$SF_DBH) {
        quest::debug("SetFocus: DB connect failed: $@") if $@;
        return;
    }
    return $SF_DBH;
}

# ==========================================================
# Internal: load DB config once per zone boot (or on demand)
# ==========================================================
sub _sf_load_config {
    my ($force_reload, $debug) = @_;

    return if $SF_CONFIG_LOADED && !$force_reload;

    my $dbh = _sf_dbh() or do {
        %SF_SETS = ();
        $SF_CONFIG_LOADED = 0;
        return;
    };

    %SF_SETS = ();

    my $sets = [];
    eval {
        my $sth = $dbh->prepare(
            "SELECT id, name
             FROM item_set_focus_sets
             WHERE enabled = 1"
        );
        $sth->execute();
        while (my $r = $sth->fetchrow_hashref) {
            push @$sets, $r;
        }
        $sth->finish;
    };
    if ($@) {
        quest::debug("SetFocus: error loading sets: $@");
        $SF_CONFIG_LOADED = 0;
        return;
    }

    # If no sets, just mark as loaded (empty config)
    if (!@$sets) {
        quest::debug("SetFocus: no enabled sets found") if $debug;
        $SF_CONFIG_LOADED = 1;
        return;
    }

    # Build set_id list
    my @set_ids = map { $_->{id} } @$sets;

    # Load items for all sets
    my %items_for_set;
    eval {
        my $in = join(",", ("?") x @set_ids);
        my $sql = "SELECT set_id, item_id
                   FROM item_set_focus_items
                   WHERE set_id IN ($in)";
        my $sth = $dbh->prepare($sql);
        $sth->execute(@set_ids);
        while (my $r = $sth->fetchrow_hashref) {
            push @{ $items_for_set{ $r->{set_id} } }, $r->{item_id};
        }
        $sth->finish;
    };
    if ($@) {
        quest::debug("SetFocus: error loading items: $@");
    }

    # Load tiers for all sets
    my %tiers_for_set;
    eval {
        my $in = join(",", ("?") x @set_ids);
        my $sql = "SELECT set_id, pieces_required, spell_id, label, sort_order
                   FROM item_set_focus_tiers
                   WHERE set_id IN ($in)
                   ORDER BY pieces_required ASC, sort_order ASC, id ASC";
        my $sth = $dbh->prepare($sql);
        $sth->execute(@set_ids);
        while (my $r = $sth->fetchrow_hashref) {
            push @{ $tiers_for_set{ $r->{set_id} } }, {
                pieces     => $r->{pieces_required} // 0,
                spell_id   => $r->{spell_id}        // 0,
                label      => $r->{label}           // '',
                sort_order => $r->{sort_order}      // 0,
            };
        }
        $sth->finish;
    };
    if ($@) {
        quest::debug("SetFocus: error loading tiers: $@");
    }

    # Build %SF_SETS
    foreach my $s (@$sets) {
        my $id    = $s->{id};
        my $name  = $s->{name} // "Set $id";
        my $items = $items_for_set{$id}  || [];
        my $tiers = $tiers_for_set{$id}  || [];

        next unless @$items && @$tiers;  # require both

        $SF_SETS{$id} = {
            name  => $name,
            items => $items,
            tiers => $tiers,
        };

        if ($debug) {
            quest::debug(
                sprintf(
                    "SetFocus: loaded set %d '%s' (%d items, %d tiers)",
                    $id, $name, scalar(@$items), scalar(@$tiers)
                )
            );
        }
    }

    $SF_CONFIG_LOADED = 1;
}

# ==========================================================
# Internal: get client referencing
# ==========================================================
sub _sf_get_client {
    my ($opt) = @_;
    $opt ||= {};
    return $opt->{client} if $opt->{client};

    my $client = plugin::val('client');
    return $client;
}

# ==========================================================
# Internal: get equipped items
# ==========================================================
sub _sf_get_equipped_items {
    my ($client) = @_;
    my %equipped;

    # Typical worn slots 0..21 (adjust if needed)
    my @SLOTS = (0..21);

    foreach my $slot (@SLOTS) {
        my $item_id = $client->GetItemIDAt($slot);
        next unless $item_id && $item_id > 0;
        $equipped{$item_id}++;
    }

    return \%equipped;
}

# ==========================================================
# Internal: best tier for count
# ==========================================================
sub _sf_best_tier_for_count {
    my ($tiers, $count) = @_;
    return undef unless $tiers && @$tiers;
    return undef unless defined $count && $count > 0;

    my $best;
    foreach my $tier (@$tiers) {
        my $needed = $tier->{pieces} // 0;
        next if $needed <= 0;
        next if $count < $needed;
        if (!$best || $needed > ($best->{pieces} // 0)) {
            $best = $tier;
        }
    }
    return $best;
}

# ==========================================================
# Internal: load state (per char + set_id)
# ==========================================================
sub _sf_load_state {
    my ($charid, $set_id) = @_;
    return undef unless $charid && $set_id;

    my $key = join(":", $SETFOCUS_BUCKET_PREFIX, $charid, $set_id);
    my $raw = quest::get_data($key);
    return undef unless defined $raw && length $raw;

    my $decoded;
    eval { $decoded = decode_json($raw); };
    return undef if $@ || ref($decoded) ne 'HASH';

    return $decoded;
}

# ==========================================================
# Internal: save state
# ==========================================================
sub _sf_save_state {
    my ($charid, $set_id, $state) = @_;
    return unless $charid && $set_id;

    my $key = join(":", $SETFOCUS_BUCKET_PREFIX, $charid, $set_id);

    if ($state) {
        my $json = encode_json($state);
        # 365 days TTL
        quest::set_data($key, $json, 86400 * 365);
    } else {
        quest::delete_data($key);
    }
}

# ==========================================================
# Internal: apply tier (fade old, cast new, update bucket)
# ==========================================================
sub _sf_apply_tier {
    my ($client, $set_id, $set_name, $best_tier, $prev_state, $debug) = @_;

    my $charid = $client->CharacterID();
    my $prev_spell  = $prev_state ? ($prev_state->{spell_id} // 0) : 0;
    my $prev_pieces = $prev_state ? ($prev_state->{pieces}  // 0) : 0;

    my $new_spell   = $best_tier ? ($best_tier->{spell_id}  // 0) : 0;
    my $new_pieces  = $best_tier ? ($best_tier->{pieces}    // 0) : 0;
    my $label       = $best_tier ? ($best_tier->{label}     // '') : '';

    # Fade old buff if it's different from the new one
    if ($prev_spell && (!$new_spell || $new_spell != $prev_spell)) {
        $client->BuffFadeBySpellID($prev_spell);
        quest::debug(
            sprintf(
                "SetFocus: faded old buff %d for set_id=%d '%s' (was %d pieces)",
                $prev_spell, $set_id, $set_name, $prev_pieces
            )
        ) if $debug;
    }

    # Apply new tier (if any)
    if ($new_spell && $new_pieces > 0) {

        if ($client->FindBuff($new_spell)) {
            quest::debug(
                sprintf(
                    "SetFocus: set_id=%d '%s' already has buff %d (tier %d)",
                    $set_id, $set_name, $new_spell, $new_pieces
                )
            ) if $debug;
        } else {
            my $cid = $client->GetID();
            $client->CastSpell($new_spell, $cid);
            quest::debug(
                sprintf(
                    "SetFocus: applied buff %d (%s) for set_id=%d '%s' (%d pieces)",
                    $new_spell, $label, $set_id, $set_name, $new_pieces
                )
            ) if $debug;
        }

        _sf_save_state($charid, $set_id, {
            spell_id => $new_spell,
            pieces   => $new_pieces,
        });

    } else {
        # No matching tier now: clear state
        if ($prev_spell) {
            $client->BuffFadeBySpellID($prev_spell);
            quest::debug(
                sprintf(
                    "SetFocus: lost all tiers for set_id=%d '%s', faded buff %d",
                    $set_id, $set_name, $prev_spell
                )
            ) if $debug;
        }
        _sf_save_state($charid, $set_id, undef);
    }
}

# ==========================================================
# Public: main entry
#
#   plugin::set_focus_update(%opts)
# ==========================================================
sub set_focus_update {
    my (%opt) = @_;

    my $client = _sf_get_client(\%opt);
    return unless $client;

    my $debug        = $opt{debug}        // 0;
    my $force_reload = $opt{force_reload} // 0;
    my $charid       = $client->CharacterID();
    return unless $charid;

    _sf_load_config($force_reload, $debug);

    # If no sets configured, do nothing
    if (!%SF_SETS) {
        quest::debug("SetFocus: no configured sets after load") if $debug;
        return;
    }

    my $equipped = _sf_get_equipped_items($client);

    # For each set, count equipped pieces and apply best tier
    foreach my $set_id (keys %SF_SETS) {
        my $set_def  = $SF_SETS{$set_id} || next;
        my $set_name = $set_def->{name}  // "Set $set_id";
        my $items    = $set_def->{items} || [];
        my $tiers    = $set_def->{tiers} || [];

        next unless @$items && @$tiers;

        # Count equipped pieces
        my $count = 0;
        foreach my $iid (@$items) {
            $count++ if $equipped->{$iid};
        }

        quest::debug(
            sprintf(
                "SetFocus: set_id=%d '%s' equipped pieces=%d",
                $set_id, $set_name, $count
            )
        ) if $debug;

        my $best_tier  = _sf_best_tier_for_count($tiers, $count);
        my $prev_state = _sf_load_state($charid, $set_id);

        # If nothing changed, skip
        if ($prev_state && $best_tier) {
            if ( ($prev_state->{spell_id} // 0) == ($best_tier->{spell_id} // 0)
              && ($prev_state->{pieces}   // 0) == ($best_tier->{pieces}   // 0) ) {
                quest::debug(
                    sprintf(
                        "SetFocus: set_id=%d '%s' no change in tier (%d pieces)",
                        $set_id, $set_name, $count
                    )
                ) if $debug;
                next;
            }
        } elsif (!$prev_state && !$best_tier) {
            next; # still nothing
        }

        # Apply / update tier
        _sf_apply_tier($client, $set_id, $set_name, $best_tier, $prev_state, $debug);
    }
}

1;
