extends Node
class_name MatchSimulation

# ---------------------------------------------------------
#  TATTICHE
# ---------------------------------------------------------

var TACTICS = {
    "4-4-2": {"attack": 1.0, "mid": 1.0, "def": 1.0},
    "4-3-3": {"attack": 1.2, "mid": 0.9, "def": 0.9},
    "3-5-2": {"attack": 1.1, "mid": 1.2, "def": 0.8},
    "4-2-3-1": {"attack": 1.15, "mid": 1.1, "def": 0.9}
}

# ---------------------------------------------------------
#  UTILITY
# ---------------------------------------------------------

func pick_player(team: Dictionary) -> Dictionary:
    var eligible = []
    for p in team["players"]:
        if p["role"] != "GK" and p.get("fatigue", 100) > 0:
            eligible.append(p)
    return eligible[randi() % eligible.size()]


func apply_fatigue(team: Dictionary) -> void:
    for p in team["players"]:
        p["fatigue"] = p.get("fatigue", 100) - randi() % 3 + 1
        if p["fatigue"] < 0:
            p["fatigue"] = 0

# ---------------------------------------------------------
#  EVENTI (1–6) + INFORTUNI
# ---------------------------------------------------------

func event_probability(player: Dictionary) -> Dictionary:
    var probs = {
        1: 0.05, # gol
        2: 0.08, # ammonizione
        3: 0.01, # espulsione
        4: 0.25, # tiro
        5: 0.20, # occasione
        6: 0.15  # fallo
    }
    var total = 0.0
    for v in probs.values():
        total += v
    for k in probs.keys():
        probs[k] = probs[k] / total
    return probs


func injury_probability(player: Dictionary) -> float:
    var form = player["form"]
    if form <= 8:
        return 0.20
    elif form <= 12:
        return 0.10
    return 0.03


func simulate_event(team: Dictionary) -> Array:
    var player = pick_player(team)
    var probs = event_probability(player)

    var r = randf()
    var cumulative = 0.0

    for event in probs.keys():
        cumulative += probs[event]
        if r <= cumulative:
            if event in [4, 6]:
                if randf() < injury_probability(player):
                    return ["infortunio", player["name"]]
            return [event, player["name"]]

    return [6, player["name"]]

# ---------------------------------------------------------
#  COMMENTO STILE CM 01/02
# ---------------------------------------------------------

func commentary(minute: int, event, player: String, team_name: String) -> String:
    match event:
        1: return "%s': GOL! %s porta avanti il %s!" % [minute, player, team_name]
        2: return "%s': Ammonito %s (%s)." % [minute, player, team_name]
        3: return "%s': ESPULSO %s! %s in dieci." % [minute, player, team_name]
        4: return "%s': Tiro di %s (%s)!" % [minute, player, team_name]
        5: return "%s': Occasione per %s (%s)!" % [minute, player, team_name]
        6: return "%s': Fallo di %s (%s)." % [minute, player, team_name]
        "infortunio": return "%s': %s (%s) si infortuna! Sostituzione obbligata." % [minute, player, team_name]
        "sostituzione": return "%s': Sostituzione %s: esce %s, entra %s." % [minute, team_name, player[0], player[1]]
    return ""

# ---------------------------------------------------------
#  SOSTITUZIONI AUTOMATICHE
# ---------------------------------------------------------

func make_substitution(team: Dictionary, minute: int, commentary_log: Array) -> void:
    var bench = []
    var starters = []

    for p in team["players"]:
        if p["fatigue"] == 0:
            bench.append(p)
        else:
            starters.append(p)

    if bench.size() == 0 or starters.size() == 0:
        return

    var out_player = starters[0]
    for p in starters:
        if p["fatigue"] < out_player["fatigue"]:
            out_player = p

    var in_player = bench[0]
    in_player["fatigue"] = 70

    commentary_log.append(
        commentary(minute, "sostituzione", [out_player["name"], in_player["name"]], team["name"])
    )

# ---------------------------------------------------------
#  VALUTAZIONI STILE CM 01/02
# ---------------------------------------------------------

func player_rating(events: Array, player_name: String) -> float:
    var score = 6.0
    for e in events:
        if e[2] == player_name:
            match e[1]:
                1: score += 1.5
                4: score += 0.2
                5: score += 0.3
                2: score -= 0.5
                3: score -= 2.0
                "infortunio": score -= 0.5
    return clamp(score, 1, 10)

# ---------------------------------------------------------
#  POSSESSO, TIRI, PASSAGGI
# ---------------------------------------------------------

func possession_share(home_team: Dictionary, away_team: Dictionary) -> Array:
    var home_mid = home_team["midfield"] * TACTICS[home_team["tactic"]]["mid"]
    var away_mid = away_team["midfield"] * TACTICS[away_team["tactic"]]["mid"]
    var total = home_mid + away_mid
    if total == 0:
        return [50, 50]
    var home_poss = int((home_mid / total) * 100)
    return [home_poss, 100 - home_poss]

# ---------------------------------------------------------
#  SIMULAZIONE COMPLETA STILE CM 01/02
# ---------------------------------------------------------

func simulate_match_full(home_team: Dictionary, away_team: Dictionary, minutes := 90) -> Dictionary:
    var events = []
    var commentary_log = []

    var stats = {
        "home_shots_on": 0,
        "home_shots_off": 0,
        "away_shots_on": 0,
        "away_shots_off": 0,
        "home_passes": 0,
        "away_passes": 0
    }

    var home_goals = 0
    var away_goals = 0
    var scorers_home = []
    var scorers_away = []

    for p in home_team["players"]:
        p["fatigue"] = 100
    for p in away_team["players"]:
        p["fatigue"] = 100

    for minute in range(1, minutes + 1):
        apply_fatigue(home_team)
        apply_fatigue(away_team)

        for team in [home_team, away_team]:
            var tired = []
            for p in team["players"]:
                if p["fatigue"] < 30:
                    tired.append(p)
            if tired.size() > 0:
                make_substitution(team, minute, commentary_log)

        if randf() < 0.8:
            stats["home_passes"] += randi() % 6 + 3
            stats["away_passes"] += randi() % 6 + 3

        if randf() < 0.30:
            var team = home_team if randf() < 0.5 else away_team
            var team_name = team["name"]

            var result = simulate_event(team)
            var event = result[0]
            var player = result[1]

            if event == 4:
                var on_target = randf() < 0.5
                if team == home_team:
                    if on_target: stats["home_shots_on"] += 1
                    else: stats["home_shots_off"] += 1
                else:
                    if on_target: stats["away_shots_on"] += 1
                    else: stats["away_shots_off"] += 1

            if event == 1:
                if team == home_team:
                    home_goals += 1
                    scorers_home.append(player)
                else:
                    away_goals += 1
                    scorers_away.append(player)

            events.append([minute, event, player, team_name])
            commentary_log.append(commentary(minute, event, player, team_name))

    var ratings_home = {}
    var ratings_away = {}

    for p in home_team["players"]:
        ratings_home[p["name"]] = player_rating(events, p["name"])

    for p in away_team["players"]:
        ratings_away[p["name"]] = player_rating(events, p["name"])

    var poss = possession_share(home_team, away_team)

    return {
        "risultato": "%s - %s" % [home_goals, away_goals],
        "marcatori_casa": scorers_home,
        "marcatori_trasferta": scorers_away,
        "commento": commentary_log,
        "statistiche": {
            "possesso_casa": poss[0],
            "possesso_trasferta": poss[1],
            "tiri_casa_in_porta": stats["home_shots_on"],
            "tiri_casa_fuori": stats["home_shots_off"],
            "tiri_trasferta_in_porta": stats["away_shots_on"],
            "tiri_trasferta_fuori": stats["away_shots_off"],
            "passaggi_casa": stats["home_passes"],
            "passaggi_trasferta": stats["away_passes"]
        },
        "valutazioni_casa": ratings_home,
        "valutazioni_trasferta": ratings_away
    }

