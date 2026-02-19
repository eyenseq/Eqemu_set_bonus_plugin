# **NEW FEATURES** #

## **Bots and pets can now benefit from item set bonus**

# Eqemu_set_bonus_plugin # **(see below for directions)**

A server-side EQEmu plugin that grants set-bonus focus effects (buff spells) when a player equips items belonging to defined sets.

The plugin fully supports:

Unlimited item sets

Multiple tier bonuses (2-piece, 4-piece, 6-piece, etc.)

DB-driven configuration

Automatic buff swapping when changing gear

Data bucket persistence per character

Zero client modifications

This system lets you build modern MMO-style gear sets with spell-based bonuses that upgrade dynamically depending on how many pieces the player is wearing.

## ✨ Features

DB-configurable item sets & tiers

Each tier applies a configurable spell containing focus/spa effects

Automatically detects gear changes (via EQUIP_ITEM_CLIENT and UNEQUIP_ITEM_CLIENT)

Casts the highest matching tier

Removes obsolete buffs when dropping below a threshold

Caches configuration for performance

Supports live reloads when sets change (optional)

## 📁 Installation

Place the plugin file into:
```text
quests/plugins/set_focus_sets.pl
```

Ensure your world server has access to the DB configuration tables (see schema below).

Add the event hooks to your global player script:

```perl
sub EVENT_ENTERZONE {
    quest::settimer("setfocus", 2);
    plugin::set_focus_update();
}

sub EVENT_TIMER {
    if ($timer eq "setfocus") {
        plugin::set_focus_update();
    }

sub EVENT_EQUIP_ITEM_CLIENT {
  return unless $client;

  return if quest::get_data("sf_equip_cd:" . $client->CharacterID());
  quest::set_data("sf_equip_cd:" . $client->CharacterID(), 1, 1);

  plugin::set_focus_update();
  }

sub EVENT_UNEQUIP_ITEM_CLIENT {
  return unless $client;

  return if quest::get_data("sf_equip_cd:" . $client->CharacterID());
  quest::set_data("sf_equip_cd:" . $client->CharacterID(), 1, 1);

  plugin::set_focus_update();
  }    
```

Add the event hooks to your global npc script:

```
sub EVENT_SPAWN {
    if ($npc->IsPet()) {
    quest::settimer("sf_pet_tick", 5);
  }

sub EVENT_TIMER  {
        if ($timer eq "sf_pet_tick") {
        return unless $npc->IsPet();

        # Pet gets evaluated independently
        plugin::set_focus_pet_tick(pet => $npc);
        }
}
```

No other events are required.

## 🗄️ Database Setup

The plugin reads configuration from three tables.
Run these SQL statements in your world database:

### 1️⃣ Item Set Definitions
```sql
CREATE TABLE IF NOT EXISTS item_set_focus_sets (
    id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    name        VARCHAR(128) NOT NULL,
    enabled     TINYINT(1) NOT NULL DEFAULT 1,
    PRIMARY KEY (id),
    UNIQUE KEY uq_item_set_focus_sets_name (name)
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 2️⃣ Items That Belong to Each Set
```sql
CREATE TABLE IF NOT EXISTS item_set_focus_items (
    id          INT UNSIGNED NOT NULL AUTO_INCREMENT,
    set_id      INT UNSIGNED NOT NULL,
    item_id     INT UNSIGNED NOT NULL,
    PRIMARY KEY (id),
    KEY idx_item_set_focus_items_set (set_id),
    KEY idx_item_set_focus_items_item (item_id),
    CONSTRAINT fk_item_set_focus_items_set
        FOREIGN KEY (set_id) REFERENCES item_set_focus_sets(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

### 3️⃣ Tier Bonuses for Each Set
```sql
CREATE TABLE IF NOT EXISTS item_set_focus_tiers (
    id               INT UNSIGNED NOT NULL AUTO_INCREMENT,
    set_id           INT UNSIGNED NOT NULL,
    pieces_required  INT UNSIGNED NOT NULL,
    spell_id         INT UNSIGNED NOT NULL,
    label            VARCHAR(128) NOT NULL DEFAULT '',
    sort_order       INT NOT NULL DEFAULT 0,
    PRIMARY KEY (id),
    KEY idx_item_set_focus_tiers_set (set_id),
    CONSTRAINT fk_item_set_focus_tiers_set
        FOREIGN KEY (set_id) REFERENCES item_set_focus_sets(id)
        ON DELETE CASCADE
) ENGINE=InnoDB DEFAULT CHARSET=utf8mb4;
```

## 🛠️ Example Configuration

### Sets
```sql
INSERT INTO item_set_focus_sets (name, enabled)
VALUES ('Tempest Warplate', 1);
```

### Items
```sql
INSERT INTO item_set_focus_items (set_id, item_id)
VALUES
(1, 50001),
(1, 50002),
(1, 50003),
(1, 50004),
(1, 50005),
(1, 50006);
```

### Tier Bonuses
```sql
INSERT INTO item_set_focus_tiers (set_id, pieces_required, spell_id, label, sort_order)
VALUES
(1, 2, 70000, '2-set: Tempest Focus I', 10),
(1, 4, 70001, '4-set: Tempest Focus II', 20),
(1, 6, 70002, '6-set: Tempest Focus III', 30);
```

Each spell_id should reference a spell in spells_new that grants the focus effect(s) you want.

## ⚙️ Configuration Reload

You can force reload the DB config on any update:

plugin::set_focus_update(force_reload => 1);


Useful after changing sets or tiers without restarting zones.

## Optional debug mode:

plugin::set_focus_update(debug => 1);

