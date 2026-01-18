# transfer_system_full.gd
# Sistema mercato completo: acquisti, vendite, prestiti, parametri zero, clausole,
# agenti e negoziazioni multi-step, visite mediche, rumors, conferenze stampa,
# scouting giovanile, contratti dettagliati (bonus, commissioni), finanza club,
# scambi multi-club, notizie stile CM01/02 e simulazione.
extends Node
class_name TransferSystemFull

# Dati esterni da popolare: teams (Dictionary), players (Array)
var teams = {}            # { "TeamName": { "name":..., "budget":..., "reputation":..., "players":[...], "form":..., "morale":... } }
var players = []          # lista di tutti i giocatori (riferimenti condivisi)
var active_loans = []     # lista prestiti attivi
var news_feed = []        # lista notizie generate durante la finestra
var rumors = []           # lista rumors attivi
var scouting_reports = [] # report generati dallo scouting

# Configurazione
const MIN_SQUAD_SIZE = 20
const MAX_SQUAD_SIZE = 25
const MAX_NEGOTIATION_ROUNDS = 4

# -------------------------
# UTILITIES
# -------------------------
func set_data(_teams: Dictionary, _players: Array) -> void:
    teams = _teams
    players = _players

func find_player_team(player: Dictionary) -> Dictionary:
    for t in teams.values():
        if player in t["players"]:
            return t
    return null

func pick_random(arr: Array):
    if arr == null or arr.size() == 0:
        return null
    return arr[randi() % arr.size()]

func now_str() -> String:
    return str(OS.get_unix_time())

# -------------------------
# FLUSSO PRINCIPALE
# -------------------------
func process_transfer_window() -> Array:
    news_feed.clear()
    generate_initial_rumors()
    run_scouting_rounds()
    # 1) valutazioni acquisti e prestiti
    for team_name in teams.keys():
        var team = teams[team_name]
        if needs_players(team):
            # preferenza: prestito -> free transfer -> acquisto -> multi-club trade
            if attempt_loan_acquisition(team):
                continue
            if attempt_free_transfer(team):
                continue
            if attempt_multi_club_trade(team):
                continue
            attempt_buy(team)
    # 2) valutazioni cessioni e prestiti out
    for team_name in teams.keys():
        var team = teams[team_name]
        attempt_sell_or_loan_out(team)
    # 3) processa prestiti mensili (durata, riscatti)
    process_monthly_loan_updates()
    # 4) aggiorna rumors e notizie
    progress_rumors()
    # 5) ritorna feed notizie
    return news_feed.duplicate()

func simulate_market(iterations: int = 1) -> Array:
    var all_news = []
    for i in range(iterations):
        var feed = process_transfer_window()
        all_news += feed
        randomize_player_forms()
        evaluate_financials()
    return all_news

# -------------------------
# DECISIONE ACQUISTO
# -------------------------
func needs_players(team: Dictionary) -> bool:
    var squad_size = team["players"].size()
    if squad_size < MIN_SQUAD_SIZE:
        return true
    if missing_key_roles(team):
        return true
    return false

func missing_key_roles(team: Dictionary) -> bool:
    var roles_needed = ["GK", "D", "M", "ST"]
    var present = {}
    for p in team["players"]:
        var r = p["role"].split(" ")[0]
        present[r] = true
    for r in roles_needed:
        if not present.has(r):
            return true
    return false

# -------------------------
# NEGOZIAZIONI E AGENTI
# -------------------------
func negotiate_transfer(player: Dictionary, from_team: Dictionary, to_team: Dictionary) -> Dictionary:
    # negoziazione multi-step con agente che chiede commissione e bonus
    var agent_fee_pct = player.get("agent_fee", 0.05) # default 5%
    var base_price = player["value"]
    var offer_price = int(base_price * (0.85 + randf() * 0.4))
    var salary_offer = int(player["wage"] * (0.9 + randf() * 0.5))
    var rounds = 0
    var accepted = false
    var final_offer = null
    while rounds < MAX_NEGOTIATION_ROUNDS and not accepted:
        rounds += 1
        # agente può chiedere commissione o bonus
        var agent_commission = int(offer_price * agent_fee_pct)
        # club vende se prezzo soddisfa o clausola di release attivata
        var seller_accepts = (offer_price >= int(base_price * 0.9)) or (player.has("release_clause") and offer_price >= player["release_clause"])
        # giocatore valuta stipendio e reputazione
        var player_accepts = (salary_offer >= player["wage"]) or (to_team["reputation"] >= player.get("reputation_needed", 6))
        # se entrambe le parti ok, accetta
        if seller_accepts and player_accepts and to_team["budget"] >= offer_price + agent_commission:
            accepted = true
            final_offer = {"price": offer_price, "salary": salary_offer, "agent_fee": agent_commission}
            break
        # altrimenti rilancio o ritiro
        if randf() < 0.5:
            # rilancio del compratore
            offer_price = int(offer_price * (1.05 + randf() * 0.1))
            salary_offer = int(salary_offer * (1.03 + randf() * 0.05))
        else:
            # possibile ritiro
            if randf() < 0.25:
                break
    return final_offer

# -------------------------
# ACQUISTO: COMPRARE
# -------------------------
func attempt_buy(team: Dictionary) -> bool:
    var budget = team["budget"]
    var targets = get_transfer_targets(budget)
    if targets.size() == 0:
        return false
    var target = pick_random(targets)
    if target == null:
        return false
    var from_team = find_player_team(target)
    var negotiation = negotiate_transfer(target, from_team, team)
    if negotiation == null:
        # fallita negoziazione, genera rumor
        push_rumor("%s vicino a %s" % [target["name"], team["name"]], "%s è stato accostato a %s" % [target["name"], team["name"]], 3)
        return false
    # visita medica
    if not medical_check(target):
        push_news("Visita medica fallita per %s" % target["name"], "%s non supera la visita medica e il trasferimento salta." % target["name"])
        return false
    # costruisci offerta con clausole
    var offer = {
        "type": "transfer",
        "player": target,
        "from_team": from_team,
        "to_team": team,
        "price": negotiation["price"],
        "salary": negotiation["salary"],
        "agent_fee": negotiation["agent_fee"],
        "clauses": build_clauses_for_offer(target, team)
    }
    if evaluate_transfer_offer(offer):
        execute_transfer_offer(offer)
        # paga commissione agente
        team["budget"] -= offer["agent_fee"]
        push_news("%s firma per %s per €%d" % [target["name"], team["name"], offer["price"]], build_article_transfer(offer))
        # conferenza stampa
        press_conference_signing(team, target)
        return true
    return false

func get_transfer_targets(budget: int) -> Array:
    var list = []
    for p in players:
        if p["status"] == "available" and not p.get("on_loan", false):
            if p["value"] <= max(0, budget * 1.2):
                list.append(p)
    return list

func evaluate_transfer_offer(offer: Dictionary) -> bool:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    var price_ok = offer["price"] >= int(player["value"] * 0.8)
    var clause_ok = true
    if player.has("release_clause"):
        clause_ok = offer["price"] >= player["release_clause"]
    var from_accepts = price_ok or clause_ok
    var salary_ok = offer["salary"] >= player["wage"]
    var reputation_ok = to_team["reputation"] >= player.get("reputation_needed", 6)
    var player_accepts = salary_ok or reputation_ok
    var to_can_pay = to_team["budget"] >= offer["price"] + offer.get("agent_fee", 0)
    return from_accepts and player_accepts and to_can_pay

func execute_transfer_offer(offer: Dictionary) -> void:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    if from_team != null and player in from_team["players"]:
        from_team["players"].erase(player)
        # applica sell-on se presente nelle clausole del giocatore
        if player.has("sell_on") and offer["price"] > 0:
            var sell_on_pct = player["sell_on"]
            var extra = int(offer["price"] * sell_on_pct)
            from_team["budget"] += extra
    to_team["players"].append(player)
    to_team["budget"] -= offer["price"]
    player["wage"] = offer["salary"]
    player["status"] = "contracted"
    if offer.has("clauses"):
        player["contract_clauses"] = offer["clauses"]

func build_clauses_for_offer(player: Dictionary, team: Dictionary) -> Dictionary:
    var clauses = {}
    if player["age"] <= 24 and randf() < 0.25:
        clauses["buy_back"] = int(player["value"] * 0.6)
    if randf() < 0.2:
        clauses["sell_on"] = 0.10 + randf() * 0.15
    if randf() < 0.15:
        clauses["release_clause"] = int(player["value"] * (1.2 + randf() * 1.5))
    # bonus obiettivi e firma
    if randf() < 0.3:
        clauses["signing_bonus"] = int(player["value"] * 0.05)
    if randf() < 0.25:
        clauses["performance_bonus"] = {"goals": 10, "amount": int(player["value"] * 0.02)}
    return clauses

# -------------------------
# PARAMETRI ZERO (FREE TRANSFERS)
# -------------------------
func attempt_free_transfer(team: Dictionary) -> bool:
    var free_list = []
    for p in players:
        if p["status"] == "free":
            free_list.append(p)
    if free_list.size() == 0:
        return false
    var target = pick_random(free_list)
    var salary_offer = int(target["wage"] * (0.8 + randf() * 0.6))
    var offer = {
        "type": "free",
        "player": target,
        "to_team": team,
        "salary": salary_offer
    }
    if evaluate_free_offer(offer):
        execute_free_transfer(offer)
        push_news("%s si unisce a %s a parametro zero" % [target["name"], team["name"]], build_article_free(offer))
        press_conference_signing(team, target)
        return true
    return false

func evaluate_free_offer(offer: Dictionary) -> bool:
    var player = offer["player"]
    var to_team = offer["to_team"]
    var salary_ok = offer["salary"] >= player["wage"] * 0.6
    var reputation_ok = to_team["reputation"] >= player.get("reputation_needed", 5)
    return (salary_ok or reputation_ok) and to_team["budget"] >= offer["salary"]

func execute_free_transfer(offer: Dictionary) -> void:
    var player = offer["player"]
    var to_team = offer["to_team"]
    to_team["players"].append(player)
    to_team["budget"] -= offer["salary"]
    player["wage"] = offer["salary"]
    player["status"] = "contracted"

# -------------------------
# PRESTITI
# -------------------------
func attempt_loan_acquisition(team: Dictionary) -> bool:
    var candidates = get_loan_targets()
    if candidates.size() == 0:
        return false
    var player = pick_random(candidates)
    var from_team = find_player_team(player)
    if from_team == null:
        return false
    var duration = player["age"] > 30 ? 6 : 12
    var loan_fee = int(player["value"] * (0.08 + randf() * 0.12))
    var wage_share = 0.5 + randf() * 0.4
    var option = randf() < 0.35
    var option_price = option ? int(player["value"] * (0.5 + randf() * 0.3)) : 0
    var recall = player["age"] < 28
    var offer = {
        "player": player,
        "from_team": from_team,
        "to_team": team,
        "duration_months": duration,
        "months_left": duration,
        "loan_fee": loan_fee,
        "wage_share_to": wage_share,
        "option_to_buy": option,
        "option_price": option_price,
        "recall_allowed": recall
    }
    if evaluate_loan_offer(offer):
        execute_loan(offer)
        push_news("%s in prestito a %s" % [player["name"], team["name"]], build_article_loan(offer))
        return true
    return false

func get_loan_targets() -> Array:
    var list = []
    for p in players:
        if p["status"] == "available" and not p.get("on_loan", false):
            if p["age"] <= 24 or p["value"] > 2000000:
                list.append(p)
    return list

func evaluate_loan_offer(offer: Dictionary) -> bool:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    var fee_ok = offer["loan_fee"] >= int(player["value"] * 0.08)
    var wants_playtime = player["form"] <= 13 or not is_player_starting(player, from_team)
    var from_accepts = fee_ok or wants_playtime
    var salary_offer = int(player["wage"] * offer["wage_share_to"])
    var reputation_ok = to_team["reputation"] >= player.get("reputation_needed", 6)
    var player_accepts = (salary_offer >= player["wage"] * 0.5) or reputation_ok
    var to_can_pay = to_team["budget"] >= offer["loan_fee"]
    return from_accepts and player_accepts and to_can_pay

func execute_loan(offer: Dictionary) -> void:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    if player in from_team["players"]:
        from_team["players"].erase(player)
    to_team["players"].append(player)
    from_team["budget"] += offer["loan_fee"]
    to_team["budget"] -= offer["loan_fee"]
    player["on_loan"] = true
    player["loan_details"] = {
        "from_team_name": from_team["name"],
        "to_team_name": to_team["name"],
        "wage_to_pay": int(player["wage"] * offer["wage_share_to"]),
        "wage_from_pay": int(player["wage"] * (1.0 - offer["wage_share_to"])),
        "months_left": offer["months_left"],
        "option_to_buy": offer["option_to_buy"],
        "option_price": offer["option_price"],
        "recall_allowed": offer["recall_allowed"]
    }
    active_loans.append(offer)

func process_monthly_loan_updates() -> void:
    var finished = []
    for offer in active_loans:
        offer["months_left"] -= 1
        var player = offer["player"]
        if player.has("loan_details"):
            player["loan_details"]["months_left"] = offer["months_left"]
        if offer["months_left"] <= 0:
            if offer["option_to_buy"] and offer["to_team"]["budget"] >= offer["option_price"]:
                finalize_purchase_from_loan(offer)
                push_news("%s riscattato da %s per €%d" % [player["name"], offer["to_team"]["name"], offer["option_price"]], "%s ha esercitato l'opzione di riscatto." % offer["to_team"]["name"])
            else:
                end_loan(offer)
                push_news("%s torna a %s" % [player["name"], offer["from_team"]["name"]], "%s ha concluso il prestito e torna al club di origine." % player["name"])
            finished.append(offer)
    for f in finished:
        active_loans.erase(f)

func end_loan(offer: Dictionary) -> void:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    if player in to_team["players"]:
        to_team["players"].erase(player)
    from_team["players"].append(player)
    player["on_loan"] = false
    player.erase("loan_details")

func finalize_purchase_from_loan(offer: Dictionary) -> void:
    var player = offer["player"]
    var from_team = offer["from_team"]
    var to_team = offer["to_team"]
    var price = offer["option_price"]
    if to_team["budget"] < price:
        end_loan(offer)
        return
    if player in from_team["players"]:
        from_team["players"].erase(player)
    if player not in to_team["players"]:
        to_team["players"].append(player)
    to_team["budget"] -= price
    from_team["budget"] += price
    player["on_loan"] = false
    player.erase("loan_details")
    player["status"] = "contracted"

func is_player_starting(player: Dictionary, team: Dictionary) -> bool:
    return player["form"] >= max(11, team.get("form", 12) - 1)

# -------------------------
# CESSIONI E PRESTITI OUT
# -------------------------
func attempt_sell_or_loan_out(team: Dictionary) -> void:
    var squad = team["players"]
    for p in squad.duplicate():
        if should_loan_out(team, p):
            offer_loan_out(team, p)
            return
        if should_sell_player(team, p):
            sell_player(team, p)
            return

func should_loan_out(team: Dictionary, player: Dictionary) -> bool:
    if player["age"] <= 23 and not is_player_starting(player, team):
        return true
    if player["form"] <= 10 and player["value"] > 200000:
        return true
    return false

func offer_loan_out(from_team: Dictionary, player: Dictionary) -> void:
    var interested = []
    for t in teams.values():
        if t == from_team:
            continue
        if needs_players(t):
            interested.append(t)
    if interested.size() == 0:
        return
    var to_team = pick_random(interested)
    var offer = {
        "player": player,
        "from_team": from_team,
        "to_team": to_team,
        "duration_months": player["age"] > 30 ? 6 : 12,
        "months_left": player["age"] > 30 ? 6 : 12,
        "loan_fee": int(player["value"] * 0.1),
        "wage_share_to": 0.5,
        "option_to_buy": randf() < 0.25,
        "option_price": int(player["value"] * 0.6),
        "recall_allowed": player["age"] < 28
    }
    if evaluate_loan_offer(offer):
        execute_loan(offer)
        push_news("%s ceduto in prestito a %s" % [player["name"], to_team["name"]], "%s lascia temporaneamente %s" % [player["name"], from_team["name"]])

func should_sell_player(team: Dictionary, player: Dictionary) -> bool:
    var squad_size = team["players"].size()
    if squad_size > MAX_SQUAD_SIZE:
        return true
    if random_offer_is_great(player):
        return true
    if player["form"] <= 10:
        return true
    return false

func random_offer_is_great(player: Dictionary) -> bool:
    return randf() < 0.05

func sell_player(team: Dictionary, player: Dictionary) -> void:
    var price = int(player["value"] * (0.7 + randf() * 0.6))
    team["players"].erase(player)
    team["budget"] += price
    player["status"] = "available"
    push_news("%s venduto da %s per €%d" % [player["name"], team["name"], price], "%s ha lasciato il club." % player["name"])
    # impatto morale
    team["morale"] = clamp(team.get("morale", 12) - 1, 8, 20)

# -------------------------
# MULTI-CLUB TRADES
# -------------------------
func attempt_multi_club_trade(team: Dictionary) -> bool:
    # cerca opportunità di scambio a catena (semplice: 3 club)
    var other_teams = []
    for t in teams.values():
        if t != team:
            other_teams.append(t)
    if other_teams.size() < 2:
        return false
    var t1 = pick_random(other_teams)
    var t2 = pick_random(other_teams)
    if t1 == t2:
        return false
    # scegli giocatori scambiabili
    var p_from = pick_random(team["players"])
    var p_t1 = pick_random(t1["players"])
    var p_t2 = pick_random(t2["players"])
    if p_from == null or p_t1 == null or p_t2 == null:
        return false
    # semplice condizione di equilibrio economico
    var value_diff = p_from["value"] + p_t1["value"] - p_t2["value"]
    if abs(value_diff) < max(100000, team["budget"] * 0.05):
        # esegui scambio circolare
        team["players"].erase(p_from)
        t1["players"].erase(p_t1)
        t2["players"].erase(p_t2)
        team["players"].append(p_t2)
        t1["players"].append(p_from)
        t2["players"].append(p_t1)
        push_news("Scambio a tre tra %s, %s e %s" % [team["name"], t1["name"], t2["name"]], "%s, %s e %s hanno completato uno scambio multiplo." % [team["name"], t1["name"], t2["name"]])
        return true
    return false

# -------------------------
# VISITE MEDICHE
# -------------------------
func medical_check(player: Dictionary) -> bool:
    # probabilità di fallimento basata su storia infortuni e età
    var injury_risk = player.get("injury_history", 0.05)
    var age_factor = clamp((player["age"] - 28) * 0.01, 0.0, 0.2)
    var fail_chance = injury_risk + age_factor
    return randf() > fail_chance

# -------------------------
# SCOUTING GIOVANILE
# -------------------------
func run_scouting_rounds() -> void:
    # genera alcuni report su giovani con potenziale
    for i in range(3):
        var candidate = pick_random(players)
        if candidate == null:
            continue
        if candidate["age"] <= 21 and candidate["value"] < 3000000:
            var potential = 12 + int(randf() * 8) # potenziale 12-20
            var report = {"player": candidate, "potential": potential, "timestamp": now_str()}
            scouting_reports.append(report)
            push_news("Scouting: %s osservato" % candidate["name"], "%s ha mostrato potenziale %d" % [candidate["name"], potential])

func get_scouting_reports() -> Array:
    return scouting_reports.duplicate()

# -------------------------
# RUMORS E EVOLUZIONE
# -------------------------
func generate_initial_rumors() -> void:
    # genera rumor casuali basati su squadre con bisogno
    for t in teams.values():
        if needs_players(t) and randf() < 0.2:
            var candidate = pick_random(players)
            if candidate:
                push_rumor("%s vicino a %s" % [candidate["name"], t["name"]], "%s è stato accostato a %s" % [candidate["name"], t["name"]], 3)

func push_rumor(headline: String, body: String, lifespan_months: int) -> void:
    var r = {"headline": headline, "body": body, "months_left": lifespan_months, "time": now_str()}
    rumors.append(r)
    push_news("Rumor: " + headline, body)

func progress_rumors() -> void:
    var finished = []
    for r in rumors:
        r["months_left"] -= 1
        if r["months_left"] <= 0:
            # rumor si evolve: 30% diventa trattativa, 10% firma, 60% svanisce
            var roll = randf()
            if roll < 0.1:
                push_news("Confermata trattativa: " + r["headline"], r["body"])
            elif roll < 0.4:
                push_news("Firma sorprendente: " + r["headline"], r["body"])
            else:
                push_news("Rumor svanito: " + r["headline"], "La voce non ha trovato seguito.")
            finished.append(r)
    for f in finished:
        rumors.erase(f)

# -------------------------
# CONFERENZE STAMPA
# -------------------------
func press_conference_signing(team: Dictionary, player: Dictionary) -> void:
    var headline = "%s presenta %s" % [team["name"], player["name"]]
    var body = "%s: 'Sono felice di essere qui. Darò tutto per la maglia'." % player["name"]
    push_news(headline, body)
    # impatto morale
    team["morale"] = clamp(team.get("morale", 12) + 1, 8, 20)
    player["morale"] = clamp(player.get("morale", 12) + 1, 8, 20)

# -------------------------
# CONTRATTI DETTAGLIATI
# -------------------------
func create_contract_with_bonuses(player: Dictionary, base_wage: int, clauses: Dictionary) -> void:
    player["wage"] = base_wage
    player["contract_clauses"] = clauses

# -------------------------
# FINANZA CLUB E FFP SEMPLIFICATO
# -------------------------
func evaluate_financials() -> void:
    # semplice controllo FFP: se budget negativo, club deve vendere
    for t in teams.values():
        if t["budget"] < 0:
            push_news("Allarme bilancio per %s" % t["name"], "%s ha bilancio negativo e deve vendere giocatori." % t["name"])
            # forza vendita del giocatore meno utile
            var candidate = pick_random(t["players"])
            if candidate:
                sell_player(t, candidate)

# -------------------------
# NOTIZIE STILE CM01/02
# -------------------------
func push_news(headline: String, body: String) -> void:
    var item = {
        "time": OS.get_unix_time(),
        "headline": headline,
        "body": body
    }
    news_feed.append(item)

func build_article_transfer(offer: Dictionary) -> String:
    var p = offer["player"]
    var t = offer["to_team"]
    var s = "Trasferimento: %s passa a %s per €%d. Clausole: " % [p["name"], t["name"], offer["price"]]
    if offer["clauses"].size() == 0:
        s += "nessuna"
    else:
        for k in offer["clauses"].keys():
            s += "%s=%s; " % [k, str(offer["clauses"][k])]
    return s

func build_article_free(offer: Dictionary) -> String:
    var p = offer["player"]
    var t = offer["to_team"]
    return "%s si unisce a %s a parametro zero con stipendio €%d" % [p["name"], t["name"], offer["salary"]]

func build_article_loan(offer: Dictionary) -> String:
    var p = offer["player"]
    var t = offer["to_team"]
    return "%s in prestito a %s fino a %d mesi. Fee €%d. Opzione riscatto: %s" % [p["name"], t["name"], offer["duration_months"], offer["loan_fee"], offer["option_to_buy"] ? str(offer["option_price"]) : "no"]

# -------------------------
# SUPPORT FUNCTIONS
# -------------------------
func randomize_player_forms() -> void:
    for p in players:
        var delta = int((randf() - 0.5) * 4)
        p["form"] = clamp(p["form"] + delta, 8, 20)
        p["morale"] = clamp(p["morale"] + int((p["form"] - 14) / 2), 8, 20)
