# game/competitions.gd
# CompetitionManager: carica squadre da res://database (JSON) e usa il match simulator in res://game/match_simulation.gd
# Supporta: Serie A, Serie B, Premier League, Eredivisie, Liga Portoghese, Bundesliga, La Liga
#           Champions League, Europa League
# Uso:
#   var cm = preload("res://game/competitions.gd").new()
#   cm.setup_from_database()  # carica database e match_simulator automaticamente
#   cm.play_league_round("Serie A")
#
extends Node
class_name CompetitionManager

# -------------------------
# CONFIGURAZIONE CAMPIONATI
# -------------------------
var leagues_config := {
    "Serie A": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 3, "uefa_spots": {"cl":3,"el":1}},
    "Serie B": {"teams": [], "rounds": 2, "promotion_spots": 3, "relegation_spots": 3, "uefa_spots": {}},
    "Premier League": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 3, "uefa_spots": {"cl":4,"el":0}},
    "Eredivisie": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 2, "uefa_spots": {"cl":2,"el":2}},
    "Liga Portoghese": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 2, "uefa_spots": {"cl":2,"el":2}},
    "Bundesliga": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 2, "uefa_spots": {"cl":4,"el":0}},
    "La Liga": {"teams": [], "rounds": 2, "promotion_spots": 0, "relegation_spots": 3, "uefa_spots": {"cl":4,"el":0}}
}

# -------------------------
# COPPE
# -------------------------
var champions_league := {
    "teams": [],
    "group_stage": {"groups": {}, "teams_per_group": 4},
    "knockout": {"rounds": []}
}
var europa_league := {
    "teams": [],
    "group_stage": {"groups": {}, "teams_per_group": 4},
    "knockout": {"rounds": []}
}

# -------------------------
# STATO E DATI DINAMICI
# -------------------------
var leagues := {}
var cups := {}
var match_simulator = null   # Callable / Funcref / instance with simulate_match(match_info)
var push_news = null         # optional callback: func(headline, body)
var on_match_finished = null # optional callback: func(match_info, result)

# -------------------------
# SETUP AUTOMATICO (database + match_simulation)
# -------------------------
func setup_from_database(database_folder: String = "res://database", cl_teams: Array = [], el_teams: Array = [], _push_news = null, _on_match_finished = null) -> void:
    # carica match simulator da res://game/match_simulation.gd
    match_simulator = _load_match_simulator("res://game/match_simulation.gd")
    push_news = _push_news
    on_match_finished = _on_match_finished
    # carica squadre JSON dalla cartella database
    var leagues_teams = _load_teams_from_folder(database_folder)
    # inizializza campionati e coppe
    _setup(leagues_teams, cl_teams, el_teams)

# Setup manuale alternativo (se si hanno già i dati)
func setup(leagues_teams: Dictionary, cl_teams: Array, el_teams: Array, _match_sim = null, _push_news = null, _on_match_finished = null) -> void:
    match_simulator = _match_sim
    push_news = _push_news
    on_match_finished = _on_match_finished
    _setup(leagues_teams, cl_teams, el_teams)

func _setup(leagues_teams: Dictionary, cl_teams: Array, el_teams: Array) -> void:
    for name in leagues_config.keys():
        var cfg = leagues_config[name]
        cfg["teams"] = leagues_teams.get(name, [])
        leagues_config[name] = cfg
        _init_league(name, cfg)
    # Coppe
    champions_league["teams"] = cl_teams.duplicate()
    europa_league["teams"] = el_teams.duplicate()
    _init_cup("Champions League", champions_league)
    _init_cup("Europa League", europa_league)

# -------------------------
# LOADER MATCH SIMULATOR (.gd)
# -------------------------
func _load_match_simulator(script_path: String) -> Object:
    # tenta di caricare e istanziare lo script in res://game/match_simulation.gd
    if not ResourceLoader.exists(script_path):
        push_warning("CompetitionManager: match_simulation non trovato in %s, userà fallback interno" % script_path)
        return null
    var script = load(script_path)
    if script == null:
        push_warning("CompetitionManager: impossibile caricare %s" % script_path)
        return null
    # prova a creare un'istanza se possibile
    var instance = null
    if script is GDScript:
        # alcuni script estendono Reference/Node e possono essere istanziati
        # se l'istanza ha simulate_match, la usiamo
        instance = script.new()
        if instance != null and instance.has_method("simulate_match"):
            return instance
        # fallback: se lo script definisce simulate_match come funzione statica, ritorna il Funcref
        if script.has_method("simulate_match"):
            return funcref(script, "simulate_match")
    # se non è GDScript o non contiene simulate_match, ritorna null
    push_warning("CompetitionManager: match_simulation caricato ma non espone simulate_match, userà fallback interno")
    return null

# -------------------------
# LOADER SQUADRE (JSON) dalla cartella database
# -------------------------
func _load_teams_from_folder(folder_path: String = "res://database") -> Dictionary:
    var dir := Directory.new()
    var leagues_teams := {
        "Serie A": [], "Serie B": [], "Premier League": [], "Eredivisie": [],
        "Liga Portoghese": [], "Bundesliga": [], "La Liga": []
    }
    if dir.open(folder_path) != OK:
        push_error("CompetitionManager: impossibile aprire cartella: %s" % folder_path)
        return leagues_teams
    dir.list_dir_begin(true, true)
    var file_name := dir.get_next()
    while file_name != "":
        if file_name.to_lower().ends_with(".json"):
            var full_path := folder_path.plus_file(file_name)
            var file := File.new()
            if file.file_exists(full_path):
                if file.open(full_path, File.READ) == OK:
                    var text := file.get_as_text()
                    file.close()
                    var parsed := JSON.parse(text)
                    if parsed.error == OK:
                        var data := parsed.result
                        if not data.has("name"):
                            push_warning("CompetitionManager: file %s ignorato (manca 'name')" % full_path)
                        else:
                            var league := _deduce_league_from_data_or_filename(data, file_name)
                            if not leagues_teams.has(league):
                                league = "Serie A"
                            leagues_teams[league].append(data)
                    else:
                        push_warning("CompetitionManager: JSON non valido in %s: %s" % [full_path, parsed.error_string])
                else:
                    push_warning("CompetitionManager: impossibile aprire file %s" % full_path)
        file_name = dir.get_next()
    dir.list_dir_end()
    return leagues_teams

func _deduce_league_from_data_or_filename(data: Dictionary, file_name: String) -> String:
    if data.has("league"):
        var l := str(data["league"])
        # normalizza
        for key in leagues_config.keys():
            if l.to_lower().findn(key.to_lower()) != -1:
                return key
    # fallback dal nome file
    var fname := file_name.to_lower()
    if fname.findn("seriea") != -1 or fname.findn("serie_a") != -1:
        return "Serie A"
    if fname.findn("serieb") != -1 or fname.findn("serie_b") != -1:
        return "Serie B"
    if fname.findn("premier") != -1:
        return "Premier League"
    if fname.findn("eredivisie") != -1:
        return "Eredivisie"
    if fname.findn("portoghes") != -1 or fname.findn("portugal") != -1:
        return "Liga Portoghese"
    if fname.findn("bundes") != -1:
        return "Bundesliga"
    if fname.findn("laliga") != -1 or fname.findn("la_liga") != -1 or fname.findn("la-liga") != -1 or fname.findn("la liga") != -1 or fname.findn("liga") != -1:
        # preferire file nominati "laliga" o "la_liga"; "liga" è generico ma considerato La Liga qui
        return "La Liga"
    return "Serie A"

# -------------------------
# INIZIALIZZAZIONE LEAGUE E CUP (interno)
# -------------------------
func _init_league(name: String, cfg: Dictionary) -> void:
    var teams_list := cfg["teams"]
    var fixtures := _create_round_robin(teams_list, cfg["rounds"])
    var standings := _create_empty_standings(teams_list)
    leagues[name] = {"fixtures": fixtures, "standings": standings, "current_round": 0, "config": cfg}

func _init_cup(name: String, cup_struct: Dictionary) -> void:
    cups[name] = {"data": cup_struct, "state": {"group_drawn": false, "current_round": 0}}

# -------------------------
# CREAZIONE CALENDARIO (Round-robin)
# -------------------------
func _create_round_robin(teams_list: Array, rounds: int) -> Array:
    var teams_copy := teams_list.duplicate()
    var n := teams_copy.size()
    if n == 0:
        return []
    if n % 2 == 1:
        teams_copy.append(null)
        n += 1
    var half := n / 2
    var schedule := []
    var order := teams_copy.duplicate()
    for r in range(rounds):
        for i in range(n - 1):
            var giornata := []
            for j in range(half):
                var t1 := order[j]
                var t2 := order[n - 1 - j]
                if t1 != null and t2 != null:
                    if (i + r) % 2 == 0:
                        giornata.append({"home": t1, "away": t2})
                    else:
                        giornata.append({"home": t2, "away": t1})
            schedule.append(giornata)
            var last := order.pop_back()
            order.insert(1, last)
    return schedule

# -------------------------
# CLASSIFICA INIZIALE
# -------------------------
func _create_empty_standings(teams_list: Array) -> Dictionary:
    var s := {}
    for t in teams_list:
        s[t["name"]] = {"team": t, "played":0, "won":0, "drawn":0, "lost":0, "gf":0, "ga":0, "gd":0, "points":0}
    return s

# -------------------------
# ESECUZIONE GIORNATA DI CAMPIONATO
# -------------------------
func play_league_round(league_name: String) -> Array:
    if not leagues.has(league_name):
        return []
    var league := leagues[league_name]
    var fixtures := league["fixtures"]
    var cr := league["current_round"]
    if cr >= fixtures.size():
        return []
    var giornata := fixtures[cr]
    var results := []
    for match in giornata:
        var match_info := {"league": league_name, "home": match["home"], "away": match["away"], "round": cr + 1}
        var result := _simulate_match(match_info)
        _update_standings(league_name, match, result)
        results.append({"match": match_info, "result": result})
        if on_match_finished != null:
            on_match_finished(match_info, result)
        if push_news != null:
            push_news("%s %s-%s: %d-%d" % [league_name, match["home"]["name"], match["away"]["name"], result["home_goals"], result["away_goals"]], "%s vs %s, giornata %d" % [match["home"]["name"], match["away"]["name"], cr + 1])
    league["current_round"] = cr + 1
    return results

# -------------------------
# SIMULAZIONE PARTITA (usa match_simulator se disponibile)
# -------------------------
func _simulate_match(match_info: Dictionary) -> Dictionary:
    if match_simulator != null:
        # match_simulator può essere: instance with simulate_match, Funcref, Callable
        if typeof(match_simulator) == TYPE_OBJECT and match_simulator is Funcref:
            return match_simulator.call_func(match_info)
        elif typeof(match_simulator) == TYPE_CALLABLE:
            return match_simulator.call(match_info)
        elif typeof(match_simulator) == TYPE_OBJECT and match_simulator.has_method("simulate_match"):
            return match_simulator.simulate_match(match_info)
    # fallback semplificato
    var home := match_info["home"]
    var away := match_info["away"]
    var home_attack := home.get("attack", 10)
    var away_defense := away.get("defense", 10)
    var away_attack := away.get("attack", 10)
    var home_defense := home.get("defense", 10)
    var home_goals := int(clamp((home_attack - away_defense) / 4.0 + randf() * 2.0, 0, 6))
    var away_goals := int(clamp((away_attack - home_defense) / 4.0 + randf() * 2.0, 0, 6))
    return {"home_goals": home_goals, "away_goals": away_goals}

# -------------------------
# AGGIORNA CLASSIFICA
# -------------------------
func _update_standings(league_name: String, match: Dictionary, result: Dictionary) -> void:
    var league := leagues[league_name]
    var s := league["standings"]
    var home := match["home"]
    var away := match["away"]
    var h := s[home["name"]]
    var a := s[away["name"]]
    var hg := result["home_goals"]
    var ag := result["away_goals"]
    h["played"] += 1
    a["played"] += 1
    h["gf"] += hg
    h["ga"] += ag
    a["gf"] += ag
    a["ga"] += hg
    h["gd"] = h["gf"] - h["ga"]
    a["gd"] = a["gf"] - a["ga"]
    if hg > ag:
        h["won"] += 1
        a["lost"] += 1
        h["points"] += 3
    elif hg < ag:
        a["won"] += 1
        h["lost"] += 1
        a["points"] += 3
    else:
        h["drawn"] += 1
        a["drawn"] += 1
        h["points"] += 1
        a["points"] += 1

# -------------------------
# OTTIENI CLASSIFICA ORDINATA
# -------------------------
func get_standings_sorted(league_name: String) -> Array:
    if not leagues.has(league_name):
        return []
    var s := leagues[league_name]["standings"]
    var arr := []
    for k in s.keys():
        arr.append(s[k])
    arr.sort_custom(self, "_sort_standings")
    return arr

func _sort_standings(a, b):
    if a["points"] != b["points"]:
        return b["points"] - a["points"]
    if a["gd"] != b["gd"]:
        return b["gd"] - a["gd"]
    return b["gf"] - a["gf"]

# -------------------------
# FINE CAMPIONATO: PROMOZIONI/RETROCESSIONI E QUALIFICAZIONI
# -------------------------
func finalize_league(league_name: String) -> Dictionary:
    if not leagues.has(league_name):
        return {}
    var cfg := leagues[league_name]["config"]
    var sorted := get_standings_sorted(league_name)
    var report := {"promoted": [], "relegated": [], "uefa": {"cl": [], "el": []}}
    if cfg["promotion_spots"] > 0:
        for i in range(cfg["promotion_spots"]):
            report["promoted"].append(sorted[i]["team"])
    if cfg["relegation_spots"] > 0:
        var n := sorted.size()
        for i in range(cfg["relegation_spots"]):
            report["relegated"].append(sorted[n - 1 - i]["team"])
    if cfg.has("uefa_spots"):
        var cl_spots := cfg["uefa_spots"].get("cl", 0)
        var el_spots := cfg["uefa_spots"].get("el", 0)
        for i in range(cl_spots):
            if i < sorted.size():
                report["uefa"]["cl"].append(sorted[i]["team"])
        for i in range(el_spots):
            var idx := cl_spots + i
            if idx < sorted.size():
                report["uefa"]["el"].append(sorted[idx]["team"])
    return report

# -------------------------
# PROMOZIONI / RETROCESSIONI TRA DUE CAMPIONATI
# -------------------------
func apply_promotion_relegation(upper_league: String, lower_league: String) -> Dictionary:
    # sposta le squadre tra upper_league e lower_league in base a promotion/relegation_spots
    if not leagues.has(upper_league) or not leagues.has(lower_league):
        return {}
    var upper_cfg := leagues[upper_league]["config"]
    var lower_cfg := leagues[lower_league]["config"]
    var upper_sorted := get_standings_sorted(upper_league)
    var lower_sorted := get_standings_sorted(lower_league)
    var releg_spots := upper_cfg.get("relegation_spots", 0)
    var promo_spots := lower_cfg.get("promotion_spots", 0)
    # sicurezza: usa min tra i due valori
    var spots := min(releg_spots, promo_spots)
    var relegated := []
    var promoted := []
    if spots <= 0:
        return {"promoted": promoted, "relegated": relegated}
    # prendi bottom 'spots' da upper e top 'spots' da lower
    var n_upper := upper_sorted.size()
    for i in range(spots):
        var r_team := upper_sorted[n_upper - 1 - i]["team"]
        relegated.append(r_team)
    for i in range(spots):
        var p_team := lower_sorted[i]["team"]
        promoted.append(p_team)
    # rimuovi dalle rispettive liste e aggiornale
    # rimuovi relegated da upper_cfg["teams"]
    for t in relegated:
        if t in upper_cfg["teams"]:
            upper_cfg["teams"].erase(t)
    # rimuovi promoted da lower_cfg["teams"]
    for t in promoted:
        if t in lower_cfg["teams"]:
            lower_cfg["teams"].erase(t)
    # aggiungi promoted in upper, relegated in lower
    for t in promoted:
        upper_cfg["teams"].append(t)
    for t in relegated:
        lower_cfg["teams"].append(t)
    # ri-inizializza i due campionati per aggiornare fixture e standings
    _init_league(upper_league, upper_cfg)
    _init_league(lower_league, lower_cfg)
    # notifica
    if push_news != null:
        for t in promoted:
            push_news("Promozione: %s sale in %s" % [t["name"], upper_league], "%s è stato promosso dalla %s alla %s." % [t["name"], lower_league, upper_league])
        for t in relegated:
            push_news("Retrocessione: %s scende in %s" % [t["name"], lower_league], "%s è stato retrocesso dalla %s alla %s." % [t["name"], upper_league, lower_league])
    return {"promoted": promoted, "relegated": relegated}

# -------------------------
# COPPE: GIRONI E KNOCKOUT
# -------------------------
func _init_cup(name: String, cup_struct: Dictionary) -> void:
    cups[name] = {"data": cup_struct, "state": {"group_drawn": false, "current_round": 0}}

func draw_group_stage(cup_name: String, teams: Array, teams_per_group: int = 4) -> void:
    if not cups.has(cup_name):
        return
    var shuffled := teams.duplicate()
    shuffled.shuffle()
    var groups := {}
    var g := int(ceil(float(shuffled.size()) / teams_per_group))
    for i in range(g):
        groups[chr(65 + i)] = []
    for i in range(shuffled.size()):
        var key := chr(65 + int(i / teams_per_group))
        groups[key].append(shuffled[i])
    cups[cup_name]["data"]["group_stage"]["groups"] = groups
    cups[cup_name]["state"]["group_drawn"] = true
    for key in groups.keys():
        var grp := groups[key]
        var standings := {}
        for t in grp:
            standings[t["name"]] = {"team": t, "played":0, "points":0, "gf":0, "ga":0, "gd":0}
        cups[cup_name]["data"]["group_stage"]["groups"][key] = {"teams": grp, "standings": standings}

func play_cup_group_round(cup_name: String) -> Array:
    if not cups.has(cup_name):
        return []
    var cup := cups[cup_name]
    if not cup["state"]["group_drawn"]:
        return []
    var results := []
    for key in cup["data"]["group_stage"]["groups"].keys():
        var group := cup["data"]["group_stage"]["groups"][key]
        var teams := group["teams"]
        if not group.has("fixtures"):
            group["fixtures"] = _create_round_robin(teams, 1)
            group["current_round"] = 0
        var cr := group["current_round"]
        if cr >= group["fixtures"].size():
            continue
        var giornata := group["fixtures"][cr]
        for match in giornata:
            var match_info := {"cup": cup_name, "group": key, "home": match["home"], "away": match["away"], "round": cr + 1}
            var result := _simulate_match(match_info)
            _update_group_standings(group["standings"], match, result)
            results.append({"match": match_info, "result": result})
            if on_match_finished != null:
                on_match_finished(match_info, result)
            if push_news != null:
                push_news("%s %s %s-%s: %d-%d" % [cup_name, key, match["home"]["name"], match["away"]["name"], result["home_goals"], result["away_goals"]], "Girone %s" % key)
        group["current_round"] = cr + 1
    return results

func _update_group_standings(standings: Dictionary, match: Dictionary, result: Dictionary) -> void:
    var home := match["home"]
    var away := match["away"]
    var h := standings[home["name"]]
    var a := standings[away["name"]]
    var hg := result["home_goals"]
    var ag := result["away_goals"]
    h["played"] += 1
    a["played"] += 1
    h["gf"] += hg
    h["ga"] += ag
    a["gf"] += ag
    a["ga"] += hg
    h["gd"] = h["gf"] - h["ga"]
    a["gd"] = a["gf"] - a["ga"]
    if hg > ag:
        h["points"] += 3
    elif hg < ag:
        a["points"] += 3
    else:
        h["points"] += 1
        a["points"] += 1

func get_group_table(cup_name: String, group_key: String) -> Array:
    if not cups.has(cup_name):
        return []
    var group := cups[cup_name]["data"]["group_stage"]["groups"].get(group_key)
    if group == null:
        return []
    var arr := []
    for k in group["standings"].keys():
        arr.append(group["standings"][k])
    arr.sort_custom(self, "_sort_group_table")
    return arr

func _sort_group_table(a, b):
    if a["points"] != b["points"]:
        return b["points"] - a["points"]
    if a["gd"] != b["gd"]:
        return b["gd"] - a["gd"]
    return b["gf"] - a["gf"]

func create_knockout_from_groups(cup_name: String) -> void:
    if not cups.has(cup_name):
        return
    var cup := cups[cup_name]
    var groups := cup["data"]["group_stage"]["groups"]
    var qualified := []
    for key in groups.keys():
        var table := get_group_table(cup_name, key)
        if table.size() >= 2:
            qualified.append(table[0]["team"])
            qualified.append(table[1]["team"])
    var pairs := []
    for i in range(0, qualified.size(), 2):
        if i + 1 < qualified.size():
            pairs.append({"home": qualified[i], "away": qualified[i + 1]})
    cup["data"]["knockout"]["rounds"] = [pairs]
    cup["state"]["current_round"] = 0

func play_knockout_round(cup_name: String) -> Array:
    if not cups.has(cup_name):
        return []
    var cup := cups[cup_name]
    if not cup["data"]["knockout"].has("rounds"):
        return []
    var cr := cup["state"].get("current_round", 0)
    if cr >= cup["data"]["knockout"]["rounds"].size():
        return []
    var pairs := cup["data"]["knockout"]["rounds"][cr]
    var winners := []
    var results := []
    for pair in pairs:
        var match_info := {"cup": cup_name, "home": pair["home"], "away": pair["away"], "round": cr + 1}
        var result := _simulate_match(match_info)
        results.append({"match": match_info, "result": result})
        if result["home_goals"] > result["away_goals"]:
            winners.append(pair["home"])
        elif result["home_goals"] < result["away_goals"]:
            winners.append(pair["away"])
        else:
            if randf() < 0.5:
                winners.append(pair["home"])
            else:
                winners.append(pair["away"])
        if on_match_finished != null:
            on_match_finished(match_info, result)
        if push_news != null:
            push_news("%s %s-%s: %d-%d" % [cup_name, pair["home"]["name"], pair["away"]["name"], result["home_goals"], result["away_goals"]], "Knockout round %d" % (cr + 1))
    var next_pairs := []
    for i in range(0, winners.size(), 2):
        if i + 1 < winners.size():
            next_pairs.append({"home": winners[i], "away": winners[i + 1]})
    if next_pairs.size() > 0:
        cup["data"]["knockout"]["rounds"].append(next_pairs)
    cup["state"]["current_round"] = cr + 1
    return results

# -------------------------
# UTILITY E HELPERS
# -------------------------
func is_league_finished(league_name: String) -> bool:
    if not leagues.has(league_name):
        return true
    var league := leagues[league_name]
    return league["current_round"] >= league["fixtures"].size()

func reset_all() -> void:
    leagues.clear()
    cups.clear()
    match_simulator = null
    push_news = null
    on_match_finished = null
