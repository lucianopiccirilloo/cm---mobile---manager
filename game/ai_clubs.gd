# team_ai.gd
# IA per la gestione delle squadre: modulo, analisi avversari, adattamento tattico, acquisti rinforzi
extends Node
class_name TeamAI

# -------------------------
# CONFIGURAZIONE
# -------------------------
var formation_preferences := ["4-3-3", "4-2-3-1", "3-5-2", "4-4-2"]
var risk_threshold := 0.5
var change_tactic_after_minutes := 30
var min_budget_for_reinforcement := 500000
var scouting_depth := 5
var max_substitutions := 3

# Riferimenti esterni (da impostare)
var teams := {}                 # dizionario delle squadre { "Name": team_dict }
var players := []               # lista globale giocatori (riferimenti condivisi)
var transfer_system := null     # riferimento opzionale al TransferSystem (adapter: attempt_buy_direct, attempt_loan_request, get_quick_scout_reports)

# -------------------------
# API PRINCIPALE
# -------------------------
func evaluate_and_act(team_name: String, match_state: Dictionary) -> void:
    var team = teams.get(team_name)
    if team == null:
        return
    # pre-partita: scegliere formazione se non impostata
    if not team.has("current_formation") or team["current_formation"] == "":
        team["current_formation"] = decide_formation(team)
    # analisi avversario
    var opponent = match_state.get("opponent_team")
    if opponent:
        var analysis = analyze_opponent(team, opponent)
        apply_pre_match_adjustments(team, analysis)
    # in partita: adattamenti tattici
    adapt_tactics_in_match(team, match_state)
    # mercato: se finestra aperta, cerca rinforzi
    if match_state.get("transfer_window_open", false):
        scout_and_buy_reinforcements(team)

# -------------------------
# SCEGLIE MODULO
# -------------------------
func decide_formation(team: Dictionary) -> String:
    var best_score := -1.0
    var best_formation := formation_preferences[0]
    for f in formation_preferences:
        var score := formation_score_for(team, f)
        if score > best_score:
            best_score = score
            best_formation = f
    return best_formation

func formation_score_for(team: Dictionary, formation: String) -> float:
    var need := {}
    match formation:
        "4-3-3":
            need = {"GK":1, "D":4, "M":3, "ST":1}
        "4-2-3-1":
            need = {"GK":1, "D":4, "M":4, "ST":1}
        "3-5-2":
            need = {"GK":1, "D":3, "M":5, "ST":2}
        "4-4-2":
            need = {"GK":1, "D":4, "M":4, "ST":2}
        _:
            need = {"GK":1, "D":4, "M":3, "ST":1}
    var score := 0.0
    var counts := role_counts(team)
    for r in need.keys():
        var have := counts.get(r, 0)
        var want := need[r]
        score += 1.0 - clamp(abs(have - want) / max(1, want), 0.0, 1.0)
    score += clamp((team.get("morale", 12) - 10) / 10.0, 0.0, 0.5)
    return score

func role_counts(team: Dictionary) -> Dictionary:
    var counts := {}
    for p in team["players"]:
        var r := p["role"].split(" ")[0]
        counts[r] = counts.get(r, 0) + 1
    return counts

# -------------------------
# ANALISI AVVERSARIO
# -------------------------
func analyze_opponent(team: Dictionary, opponent: Dictionary) -> Dictionary:
    var opp_strength := {
        "attack": opponent.get("attack", 10),
        "midfield": opponent.get("midfield", 10),
        "defense": opponent.get("defense", 10),
        "width": opponent.get("width", 10)
    }
    var weaknesses := []
    if opp_strength["defense"] < opp_strength["attack"]:
        weaknesses.append("defense")
    if opp_strength["midfield"] < opp_strength["attack"]:
        weaknesses.append("midfield")
    if opp_strength["width"] < 12:
        weaknesses.append("flanks")
    return {"opp_strength": opp_strength, "weaknesses": weaknesses}

func apply_pre_match_adjustments(team: Dictionary, analysis: Dictionary) -> void:
    var weaknesses := analysis["weaknesses"]
    if "defense" in weaknesses:
        team["preferred_style"] = "attacking"
    elif "midfield" in weaknesses:
        team["preferred_style"] = "control"
    elif "flanks" in weaknesses:
        team["preferred_style"] = "exploit_flanks"
    else:
        team["preferred_style"] = "balanced"

# -------------------------
# ADATTAMENTO TATTICO IN PARTITA
# -------------------------
func adapt_tactics_in_match(team: Dictionary, match_state: Dictionary) -> void:
    var team_score := match_state.get("team_score", 0)
    var opp_score := match_state.get("opponent_score", 0)
    var score_diff := team_score - opp_score
    var minute := match_state.get("minute", 0)
    if score_diff < 0 and minute >= change_tactic_after_minutes:
        var deficit := abs(score_diff)
        if deficit == 1:
            make_moderate_change(team)
        else:
            make_aggressive_change(team)
    elif score_diff > 0:
        consolidate_defensive(team)

func make_moderate_change(team: Dictionary) -> void:
    var current := team.get("current_formation", "4-3-3")
    var alt := pick_more_offensive_formation(current)
    if alt != current:
        team["current_formation"] = alt
        team["tactic_change_time"] = OS.get_unix_time()
        team["mentalita"] = "positive"
    else:
        team["mentalita"] = "attacking"

func make_aggressive_change(team: Dictionary) -> void:
    team["mentalita"] = "very_attacking"
    var sub := find_best_substitute_for_role(team, "ST")
    if sub:
        apply_substitution(team, sub)
    team["current_formation"] = pick_most_offensive_formation(team)

func consolidate_defensive(team: Dictionary) -> void:
    team["mentalita"] = "defensive"
    var sub := find_best_substitute_for_role(team, "DM")
    if sub:
        apply_substitution(team, sub)

func pick_more_offensive_formation(current: String) -> String:
    var order := ["4-4-2", "4-3-3", "4-2-3-1", "3-5-2"]
    var idx := order.find(current)
    if idx == -1:
        return current
    var new_idx := max(0, idx - 1)
    return order[new_idx]

func pick_most_offensive_formation(team: Dictionary) -> String:
    var counts := role_counts(team)
    if counts.get("ST", 0) >= 2:
        return "3-5-2"
    return "4-3-3"

func find_best_substitute_for_role(team: Dictionary, role_prefix: String) -> Dictionary:
    var best := null
    var best_form := -999
    for p in team["players"]:
        if not p.get("is_starting", false) and p["role"].begins_with(role_prefix):
            if p["form"] > best_form:
                best_form = p["form"]
                best = p
    return best

func apply_substitution(team: Dictionary, player_in: Dictionary) -> void:
    if player_in == null:
        return
    player_in["is_starting"] = true
    player_in["fatigue"] = 100
    team["morale"] = clamp(team.get("morale", 12) + 1, 8, 20)
    push_team_log(team["name"], "Sostituzione: inserito %s" % player_in["name"])

func push_team_log(team_name: String, text: String) -> void:
    print("[%s] %s" % [team_name, text])

# -------------------------
# SCOUTING E ACQUISTO RINFORZI
# -------------------------
func scout_and_buy_reinforcements(team: Dictionary) -> void:
    var needs := evaluate_transfer_needs(team)
    if needs.size() == 0:
        return
    var reports := []
    if transfer_system and transfer_system.has_method("get_quick_scout_reports"):
        reports = transfer_system.get_quick_scout_reports(team, scouting_depth)
    else:
        reports = quick_scout_targets(needs, scouting_depth)
    var targets := []
    for r in reports:
        var p := r.has("player") ? r["player"] : r
        var role := p["role"].split(" ")[0]
        if role in needs:
            targets.append(p)
    targets.sort_custom(self, "_sort_targets")
    for t in targets:
        if t["value"] <= team["budget"] and team["budget"] >= min_budget_for_reinforcement:
            if t["age"] <= 24 and transfer_system and transfer_system.has_method("attempt_loan_request"):
                if transfer_system.attempt_loan_request(team, t):
                    push_team_log(team["name"], "Preso in prestito %s" % t["name"])
                    return
            if transfer_system and transfer_system.has_method("attempt_buy_direct"):
                if transfer_system.attempt_buy_direct(team, t):
                    push_team_log(team["name"], "Acquistato %s" % t["name"])
                    return
            else:
                simple_purchase(team, t)
                return

func evaluate_transfer_needs(team: Dictionary) -> Array:
    var needs := []
    var counts := role_counts(team)
    if counts.get("GK", 0) < 2:
        needs.append("GK")
    if counts.get("D", 0) < 4:
        needs.append("D")
    if counts.get("M", 0) < 4:
        needs.append("M")
    if counts.get("ST", 0) < 2:
        needs.append("ST")
    for p in team["players"]:
        if p["form"] <= 10:
            var r := p["role"].split(" ")[0]
            if r not in needs:
                needs.append(r)
    return needs

func quick_scout_targets(needs: Array, depth: int) -> Array:
    var candidates := []
    for p in players:
        if p["status"] == "available" and not p.get("on_loan", false):
            var r := p["role"].split(" ")[0]
            if r in needs:
                candidates.append(p)
    candidates.sort_custom(self, "_sort_targets")
    return candidates.slice(0, min(depth, candidates.size()))

func _sort_targets(a, b):
    var score_a := a["form"] * 2 - a["value"] / 1000000.0
    var score_b := b["form"] * 2 - b["value"] / 1000000.0
    return
