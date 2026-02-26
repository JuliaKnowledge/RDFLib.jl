using Test
using RDFLib

@testset "ProbLog" begin

# ─── Parser Tests ─────────────────────────────────────────────────────────

@testset "Parser basics" begin
    prog = parse_problog("0.5::heads1. 0.6::heads2. someHeads :- heads1. query(someHeads).")
    @test length(prog.clauses) == 3
    @test prog.clauses[1].prob == 0.5
    @test prog.clauses[1].head.predicate == "heads1"
    @test prog.clauses[2].prob == 0.6
    @test prog.clauses[3].prob == 1.0
    @test length(prog.clauses[3].body) == 1
    @test length(prog.queries) == 1
end

@testset "Parser with arguments" begin
    prog = parse_problog("0.3::stress(ann). smokes(X) :- stress(X). query(smokes(ann)).")
    @test prog.clauses[1].head.predicate == "stress"
    @test prog.clauses[1].head.args == ["ann"]
    @test prog.clauses[2].head.predicate == "smokes"
    @test prog.clauses[2].body[1].predicate == "stress"
end

@testset "Parser <- syntax" begin
    prog = parse_problog("0.8::alarm <- burglary. query(alarm).")
    @test prog.clauses[1].prob == 0.8
    @test prog.clauses[1].head.predicate == "alarm"
    @test prog.clauses[1].body[1].predicate == "burglary"
end

@testset "Parser negation \\+" begin
    prog = parse_problog("p :- \\+a. query(p).")
    @test prog.clauses[1].body[1].negated == true
    @test prog.clauses[1].body[1].predicate == "a"
end

@testset "Parser evidence" begin
    prog = parse_problog("0.5::a. evidence(a, true). evidence(b, false). query(a).")
    @test length(prog.evidence) == 2
    @test prog.evidence[1][2] == true
    @test prog.evidence[2][2] == false
end

@testset "Parser wildcards" begin
    prog = parse_problog("someHeads :- heads(_). query(someHeads).")
    # Wildcard _ gets replaced with unique variable names
    @test prog.clauses[1].body[1].args[1] != "_"
    @test startswith(prog.clauses[1].body[1].args[1], "_W")
end

# ─── ProbLog Test Suite: Trivial Cases ────────────────────────────────────

@testset "00_trivial_true" begin
    r = problog_query("a. query(a).")
    @test r["a"] ≈ 1.0
end

@testset "00_trivial_and (twoHeads)" begin
    # problog/test/00_trivial_and.pl
    r = problog_query("""
        0.5::heads1. 0.6::heads2.
        twoHeads :- heads1, heads2.
        query(heads1). query(heads2). query(twoHeads).
    """)
    @test r["heads1"] ≈ 0.5
    @test r["heads2"] ≈ 0.6
    @test r["twoHeads"] ≈ 0.3
end

@testset "00_trivial_or (someHeads)" begin
    # problog/test/00_trivial_or.pl
    r = problog_query("""
        0.5::heads1. 0.6::heads2.
        someHeads :- heads1. someHeads :- heads2.
        query(heads1). query(heads2). query(someHeads).
    """)
    @test r["heads1"] ≈ 0.5
    @test r["heads2"] ≈ 0.6
    @test r["someHeads"] ≈ 0.8
end

@testset "00_trivial_not" begin
    # problog/test/00_trivial_not.pl
    r = problog_query("""
        0.4::a.
        p :- \\+a.
        query(p).
    """)
    @test r["p"] ≈ 0.6
end

# ─── ProbLog Test Suite: Coins ────────────────────────────────────────────

@testset "coin.pl (someHeads + twoHeads)" begin
    # problog/test/coin.pl
    r = problog_query("""
        0.5::heads1. 0.6::heads2.
        twoHeads :- heads1, heads2.
        someHeads :- heads1. someHeads :- heads2.
        query(someHeads). query(twoHeads).
    """)
    @test r["someHeads"] ≈ 0.8
    @test r["twoHeads"] ≈ 0.3
end

@testset "3_tossing_coin.pl (4 coins, wildcard)" begin
    # problog/test/3_tossing_coin.pl — uses wildcard _ and probabilistic rules
    r = problog_query("""
        0.6::heads(C) :- coin(C).
        coin(c1). coin(c2). coin(c3). coin(c4).
        someHeads :- heads(_).
        query(someHeads).
    """)
    @test r["someHeads"] ≈ 0.9744 atol=1e-10
end

# ─── ProbLog Test Suite: tc_* ─────────────────────────────────────────────

@testset "tc_1.pl (multi-instance probabilistic facts)" begin
    # problog/test/tc_1.pl
    r = problog_query("""
        0.2::stressed(1).
        0.2::stressed(X) :- person(X).
        person(1). person(2).
        query(stressed(1)). query(stressed(2)).
    """)
    @test r["stressed(1)"] ≈ 0.36 atol=1e-10
    @test r["stressed(2)"] ≈ 0.2 atol=1e-10
end

@testset "tc_2.pl (evidence conditioning)" begin
    # problog/test/tc_2.pl — requires Bayesian conditioning
    r = problog_query("""
        0.2::r <- a.
        0.2::h <- r.
        0.2::a.
        0.2::r.
        evidence(h, true).
        query(a).
    """)
    @test r["a"] ≈ 0.3103448275862069 atol=1e-10
end

@testset "tc_3.pl (stressed students)" begin
    # problog/test/tc_3.pl
    r = problog_query("""
        0.5::stressed(X) :- student(X).
        0.2::stressed(X) :- athlet(X).
        athlet(1). athlet(2). student(2). student(3).
        query(stressed(1)). query(stressed(2)). query(stressed(3)).
    """)
    @test r["stressed(1)"] ≈ 0.2 atol=1e-10
    @test r["stressed(2)"] ≈ 0.6 atol=1e-10
    @test r["stressed(3)"] ≈ 0.5 atol=1e-10
end

# ─── ProbLog Test Suite: Bayesian Networks ────────────────────────────────

@testset "4_bayesian_net.pl (alarm, negation + evidence)" begin
    # problog/test/4_bayesian_net.pl
    r = problog_query("""
        0.7::burglary. 0.2::earthquake.
        0.9::p_alarm1. 0.8::p_alarm2. 0.1::p_alarm3.
        alarm :- burglary, earthquake, p_alarm1.
        alarm :- burglary, \\+earthquake, p_alarm2.
        alarm :- \\+burglary, earthquake, p_alarm3.
        evidence(alarm, true).
        query(burglary). query(earthquake).
    """)
    @test r["burglary"] ≈ 0.9896551724137932 atol=1e-10
    @test r["earthquake"] ≈ 0.2275862068965517 atol=1e-10
end

@testset "5_bayesian_net.pl (alarm + calls, <- syntax)" begin
    # problog/test/5_bayesian_net.pl
    r = problog_query("""
        person(john). person(mary).
        0.7::burglary. 0.2::earthquake.
        0.9::alarm <- burglary, earthquake.
        0.8::alarm <- burglary, \\+earthquake.
        0.1::alarm <- \\+burglary, earthquake.
        0.8::calls(X) <- alarm, person(X).
        0.1::calls(X) <- \\+alarm, person(X).
        evidence(calls(john), true). evidence(calls(mary), true).
        query(burglary). query(earthquake).
    """)
    @test r["burglary"] ≈ 0.9819392647842303 atol=1e-8
    @test r["earthquake"] ≈ 0.22685135855087904 atol=1e-8
end

# ─── ProbLog Test Suite: Graphs ───────────────────────────────────────────

@testset "7_probabilistic_graph.pl (inequality \\==)" begin
    # problog/test/7_probabilistic_graph.pl
    r = problog_query("""
        0.6::edge(1,2). 0.1::edge(1,3). 0.4::edge(2,5). 0.3::edge(2,6).
        0.3::edge(3,4). 0.8::edge(4,5). 0.2::edge(5,6).
        path(X,Y) :- edge(X,Y).
        path(X,Y) :- edge(X,Z), Y \\== Z, path(Z,Y).
        query(path(1,5)). query(path(1,6)).
    """)
    @test r["path(1,5)"] ≈ 0.25824 atol=1e-10
    @test r["path(1,6)"] ≈ 0.2167296 atol=1e-6
end

@testset "Diamond path (shared dependencies, exact BDD)" begin
    # Two paths a→b→c→d and a→c→d share edge(c,d)
    r = problog_query("""
        0.9::edge(a,b). 0.8::edge(b,c). 0.7::edge(a,c). 0.6::edge(c,d).
        path(X,Y) :- edge(X,Y).
        path(X,Y) :- edge(X,Z), path(Z,Y).
        query(path(a,d)).
    """)
    @test r["path(a,d)"] ≈ 0.5496 atol=1e-10
end

# ─── ProbLog Test Suite: Smokers Network ──────────────────────────────────

@testset "8_smokers_network.pl (full network with evidence)" begin
    # problog/test/8_smokers_network.pl
    r = problog_query("""
        0.3::stress(X) :- person(X).
        0.2::influences(X,Y) :- person(X), person(Y).
        smokes(X) :- stress(X).
        smokes(X) :- friend(X,Y), influences(Y,X), smokes(Y).
        0.4::asthma(X) <- smokes(X).
        person(1). person(2). person(3). person(4).
        friend(1,2). friend(2,1). friend(2,4). friend(3,2). friend(4,2).
        evidence(smokes(2), true). evidence(influences(4,2), false).
        query(smokes(1)). query(smokes(2)). query(smokes(3)). query(smokes(4)).
        query(asthma(1)). query(asthma(2)). query(asthma(3)). query(asthma(4)).
    """)
    @test r["smokes(1)"] ≈ 0.5087719298245614 atol=1e-8
    @test r["smokes(2)"] ≈ 1.0 atol=1e-10
    @test r["smokes(3)"] ≈ 0.44 atol=1e-8
    @test r["smokes(4)"] ≈ 0.44 atol=1e-8
    @test r["asthma(1)"] ≈ 0.20350877192982458 atol=1e-8
    @test r["asthma(2)"] ≈ 0.4 atol=1e-8
    @test r["asthma(3)"] ≈ 0.176 atol=1e-8
    @test r["asthma(4)"] ≈ 0.176 atol=1e-8
end

@testset "Small smokers (recursive, no evidence)" begin
    r = problog_query("""
        0.3::stress(ann). 0.2::stress(bob).
        0.3::influences(ann,bob). 0.3::influences(bob,ann).
        smokes(X) :- stress(X).
        smokes(X) :- influences(Y,X), smokes(Y).
        query(smokes(ann)). query(smokes(bob)).
    """)
    @test r["smokes(ann)"] ≈ 0.342 atol=1e-10
    @test r["smokes(bob)"] ≈ 0.272 atol=1e-10
end

@testset "Larger smokers (3-node chain, no evidence)" begin
    r = problog_query("""
        0.2::stress(1). 0.5::stress(2).
        0.3::friends(1,2). 0.4::friends(2,3).
        influences(X,Y) :- friends(X,Y).
        smokes(X) :- stress(X).
        smokes(X) :- influences(Y,X), smokes(Y).
        query(smokes(1)). query(smokes(2)). query(smokes(3)).
    """)
    @test r["smokes(1)"] ≈ 0.2 atol=1e-10
    @test r["smokes(2)"] ≈ 0.53 atol=1e-10
    @test r["smokes(3)"] ≈ 0.212 atol=1e-10
end

# ─── Additional Inference Tests ───────────────────────────────────────────

@testset "Simple transitive path" begin
    r = problog_query("""
        0.9::edge(a,b). 0.8::edge(b,c).
        path(X,Y) :- edge(X,Y).
        path(X,Z) :- edge(X,Y), path(Y,Z).
        query(path(a,b)). query(path(a,c)). query(path(b,c)).
    """)
    @test r["path(a,b)"] ≈ 0.9
    @test r["path(b,c)"] ≈ 0.8
    @test r["path(a,c)"] ≈ 0.72
end

@testset "Chain rule (AND)" begin
    r = problog_query("0.9::a. 0.8::b. c :- a, b. query(c).")
    @test r["c"] ≈ 0.72
end

@testset "Multiple OR derivations" begin
    r = problog_query("0.3::a. 0.5::b. c :- a. c :- b. query(c).")
    @test r["c"] ≈ 0.65
end

@testset "Multi-OR (3 sources)" begin
    r = problog_query("""
        0.3::x1. 0.5::x2. 0.4::x3.
        y :- x1. y :- x2. y :- x3.
        query(y).
    """)
    @test r["y"] ≈ 0.79 atol=1e-10
end

@testset "Zero probability" begin
    r = problog_query("0.0::a. b :- a. query(b).")
    @test r["b"] ≈ 0.0
end

@testset "Certainty (prob=1.0)" begin
    r = problog_query("1.0::a. b :- a. query(b).")
    @test r["b"] ≈ 1.0
end

@testset "Multiple facts same predicate (OR)" begin
    r = problog_query("0.3::a. 0.5::a. query(a).")
    @test r["a"] ≈ 1.0 - (1-0.3)*(1-0.5)  # 0.65
end

@testset "Empty program" begin
    r = problog_query("query(a).")
    @test r["a"] ≈ 0.0
end

@testset "No matching query" begin
    r = problog_query("0.5::a. query(b).")
    @test r["b"] ≈ 0.0
end

@testset "Evidence simple" begin
    r = problog_query("""
        0.5::rain. 0.3::wind.
        bad_weather :- rain. bad_weather :- wind.
        evidence(rain, true).
        query(rain). query(bad_weather).
    """)
    @test r["rain"] ≈ 1.0
    @test r["bad_weather"] ≈ 1.0  # rain is certain → bad_weather is certain
end

@testset "Evidence false" begin
    r = problog_query("""
        0.5::a. 0.3::b.
        c :- a. c :- b.
        evidence(a, false).
        query(c).
    """)
    # P(c|¬a) = P(c ∧ ¬a)/P(¬a) = P(b ∧ ¬a)/P(¬a) = P(b)/1 = 0.3
    @test r["c"] ≈ 0.3 atol=1e-10
end

@testset "Ground variables" begin
    r = problog_query("""
        0.5::p(a). 0.3::p(b).
        q(X) :- p(X).
        query(q(a)). query(q(b)).
    """)
    @test r["q(a)"] ≈ 0.5
    @test r["q(b)"] ≈ 0.3
end

@testset "Multi-arg join" begin
    r = problog_query("""
        0.9::parent(alice,bob). 0.8::parent(bob,carol).
        grandparent(X,Z) :- parent(X,Y), parent(Y,Z).
        query(grandparent(alice,carol)).
    """)
    @test r["grandparent(alice,carol)"] ≈ 0.72
end

@testset "Negation chains" begin
    # a=0.4, b = ¬a = 0.6, c = a ∧ ¬a = 0
    r = problog_query("""
        0.4::a.
        b :- \\+a.
        c :- a, \\+a.
        query(a). query(b). query(c).
    """)
    @test r["a"] ≈ 0.4
    @test r["b"] ≈ 0.6
    @test r["c"] ≈ 0.0
end

@testset "Probabilistic rule (prob < 1.0 on rule)" begin
    # 0.8::alarm :- burglary means alarm is true with prob 0.8 given burglary
    r = problog_query("""
        0.5::burglary.
        0.8::alarm <- burglary.
        query(alarm).
    """)
    @test r["alarm"] ≈ 0.4 atol=1e-10
end

@testset "Non-ground query" begin
    # problog/test/non_ground_query.pl (simplified — without arithmetic)
    r = problog_query("""
        0.2::b(2).
        d(1). d(2). d(3).
        c(X,Y) :- d(X), d(Y).
        a(X) :- b(2), c(X,Y).
        query(a(1)). query(a(2)). query(a(3)).
    """)
    @test r["a(1)"] ≈ 0.2
    @test r["a(2)"] ≈ 0.2
    @test r["a(3)"] ≈ 0.2
end

# ─── Additional ProbLog Test Suite Cases ──────────────────────────────────

@testset "00_trivial_fact.pl" begin
    # problog/test/00_trivial_fact.pl
    r = problog_query("0.3::a. 0.5::b. query(a). query(b).")
    @test r["a"] ≈ 0.3
    @test r["b"] ≈ 0.5
end

@testset "00_trivial_not_and.pl" begin
    # problog/test/00_trivial_not_and.pl
    r = problog_query("""
        0.5::a. 0.3::b.
        q :- a, b.
        p :- \\+q.
        query(p).
    """)
    @test r["p"] ≈ 0.85 atol=1e-10
end

@testset "00_trivial_fail.pl" begin
    # problog/test/00_trivial_fail.pl — `fail` is undefined, so a=0.0
    r = problog_query("a :- fail. query(a).")
    @test r["a"] ≈ 0.0
end

@testset "00_trivial_duplicate.pl" begin
    # problog/test/00_trivial_duplicate.pl — duplicate facts are independent
    r = problog_query("""
        0.3::p(1). 0.2::p(2). 0.6::p(1).
        query(p(1)). query(p(2)).
    """)
    @test r["p(1)"] ≈ 0.72 atol=1e-10  # 1-(1-0.3)(1-0.6)
    @test r["p(2)"] ≈ 0.2
end

@testset "negation.pl (complex negation)" begin
    # problog/test/negation.pl
    r = problog_query("""
        0.2::a. 0.7::b.
        c :- a, b.
        c :- a, \\+b.
        q1 :- b, c.
        q2 :- \\+b, c.
        query(q1). query(q2).
    """)
    @test r["q1"] ≈ 0.14 atol=1e-10
    @test r["q2"] ≈ 0.06 atol=1e-10
end

@testset "negative_query.pl" begin
    # problog/test/negative_query.pl — query(\\+p)
    r = problog_query("0.3::p. query(\\+p).")
    @test r["\\+p"] ≈ 0.7 atol=1e-10
end

@testset "4_1_bayesian_net.pl (<- syntax)" begin
    # problog/test/4_1_bayesian_net.pl — same as 4_ but with <- syntax
    r = problog_query("""
        0.7::burglary. 0.2::earthquake.
        0.9::alarm <- burglary, earthquake.
        0.8::alarm <- burglary, \\+earthquake.
        0.1::alarm <- \\+burglary, earthquake.
        evidence(alarm, true).
        query(burglary). query(earthquake).
    """)
    @test r["burglary"] ≈ 0.9896551724137932 atol=1e-10
    @test r["earthquake"] ≈ 0.2275862068965517 atol=1e-10
end

@testset "evidence_bug.pl (unrelated evidence)" begin
    # problog/test/evidence_bug.pl — evidence on q doesn't affect a1/a2
    r = problog_query("""
        0.4::a. 0.3::b. 0.5::q.
        a1 :- b, a. a2 :- b.
        query(a1). query(a2).
        evidence(q, true).
    """)
    @test r["a1"] ≈ 0.12 atol=1e-10
    @test r["a2"] ≈ 0.3 atol=1e-10
end

@testset "evidence_bug_alt.pl (reordered)" begin
    # problog/test/evidence_bug_alt.pl
    r = problog_query("""
        0.4::a. 0.3::b. 0.5::q.
        a2 :- b, a. a1 :- b.
        query(a2). query(a1).
        evidence(q, true).
    """)
    @test r["a2"] ≈ 0.12 atol=1e-10
    @test r["a1"] ≈ 0.3 atol=1e-10
end

@testset "advars.pl (intensional probabilistic facts)" begin
    # problog/test/advars.pl
    r = problog_query("""
        0.3::e1(X,Y) :- a1(X,Z), b1(Z,Y).
        0.3::e2(X,Y) :- a2(X,Z), b2(Z,Y).
        a1(1,2). b1(2,4).
        a2(1,2). b2(2,4). a2(1,3). b2(3,4).
        query(e1(1,4)). query(e2(1,4)).
    """)
    @test r["e1(1,4)"] ≈ 0.3 atol=1e-10
    @test r["e2(1,4)"] ≈ 0.51 atol=1e-10
end

@testset "swap.pl (graph cycles)" begin
    # problog/test/swap.pl — tests rule ordering doesn't matter
    r = problog_query("""
        0.5::f(1,2). 0.5::f(2,1). 0.5::f(1,3). 0.5::f(2,3).
        0.5::b(X).
        s1(X) :- b(X).
        s1(X) :- f(X,Y), s1(Y).
        s2(X) :- f(X,Y), s2(Y).
        s2(X) :- b(X).
        query(s1(1)). query(s2(1)).
    """)
    @test r["s1(1)"] ≈ 0.734375 atol=1e-6
    @test r["s2(1)"] ≈ 0.734375 atol=1e-6
end

@testset "same_var.pl (same-variable binding)" begin
    # problog/test/same_var.pl — in(a,b) doesn't match in(X,X) since a≠b
    r = problog_query("in(a,b). score :- in(X,X). query(score).")
    @test r["score"] ≈ 0.0
end

@testset "advars_smokers.pl (full smokers, single evidence)" begin
    # problog/test/advars_smokers.pl — only evidence(smokes(2),true)
    r = problog_query("""
        0.3::stress(X) :- person(X).
        0.2::influences(X,Y) :- person(X), person(Y).
        smokes(X) :- stress(X).
        smokes(X) :- friend(X,Y), influences(Y,X), smokes(Y).
        0.4::asthma(X) :- smokes(X).
        person(1). person(2). person(3). person(4).
        friend(1,2). friend(2,1). friend(2,4). friend(3,2). friend(4,2).
        evidence(smokes(2), true).
        query(smokes(1)). query(smokes(2)). query(smokes(3)). query(smokes(4)).
        query(asthma(1)). query(asthma(2)). query(asthma(3)). query(asthma(4)).
    """)
    @test r["smokes(1)"] ≈ 0.49795533 atol=1e-6
    @test r["smokes(2)"] ≈ 1.0
    @test r["smokes(3)"] ≈ 0.44 atol=1e-6
    @test r["smokes(4)"] ≈ 0.49795533 atol=1e-6
    @test r["asthma(1)"] ≈ 0.19918213 atol=1e-6
    @test r["asthma(2)"] ≈ 0.4 atol=1e-6
    @test r["asthma(3)"] ≈ 0.176 atol=1e-6
    @test r["asthma(4)"] ≈ 0.19918213 atol=1e-6
end

@testset "advars_smokers_alt.pl (probabilistic influence rule)" begin
    # problog/test/advars_smokers_alt.pl — 0.2::smokes(X) :- friend(X,Y), smokes(Y)
    r = problog_query("""
        0.3::stress(X) :- person(X).
        smokes(X) :- stress(X).
        0.2::smokes(X) :- friend(X,Y), smokes(Y).
        0.4::asthma(X) :- smokes(X).
        person(1). person(2). person(3). person(4).
        friend(1,2). friend(2,1). friend(2,4). friend(3,2). friend(4,2).
        evidence(smokes(2), true).
        query(smokes(1)). query(smokes(3)). query(smokes(4)).
        query(asthma(1)). query(asthma(3)). query(asthma(4)).
    """)
    @test r["smokes(1)"] ≈ 0.49795533 atol=1e-6
    @test r["smokes(3)"] ≈ 0.44 atol=1e-6
    @test r["smokes(4)"] ≈ 0.49795533 atol=1e-6
    @test r["asthma(1)"] ≈ 0.19918213 atol=1e-6
    @test r["asthma(3)"] ≈ 0.176 atol=1e-6
    @test r["asthma(4)"] ≈ 0.19918213 atol=1e-6
end

@testset "some_cycles.pl (vulnerability propagation)" begin
    # problog/test/some_cycles.pl
    r = problog_query("""
        1.0::isVulnerable(X) <- hasVuln(X,Z), vuln(Z).
        1.0::isVulnerable(X) <- influencedBy(X,Y), isVulnerable(Y).
        0.2::influencedBy(zz,q). 0.8::influencedBy(w,zz).
        0.4::influencedBy(q,zz). 0.9::influencedBy(zz,w).
        0.7::influencedBy(d,q). 0.3::influencedBy(d,w).
        1.0::hasVuln(w,vw). 1.0::hasVuln(q,vq).
        0.5::vuln(vw). 0.7::vuln(vq).
        query(isVulnerable(d)).
    """)
    @test r["isVulnerable(d)"] ≈ 0.598 atol=1e-6
end

@testset "generated.pl (54-query propositional network)" begin
    # problog/test/generated.pl — auto-generated BN with 54 queries
    source = read(joinpath(@__DIR__, "..", "..", "problog", "test", "generated.pl"), String)
    r = problog_query(source)
    expected = Dict{String,Float64}()
    for line in split(source, "\n")
        m = match(r"^%\s+(\S+)\s+([\d.eE\+\-]+)\s*$", line)
        if m !== nothing
            expected[String(m.captures[1])] = parse(Float64, String(m.captures[2]))
        end
    end
    @test length(r) == 54
    for (k, exp) in expected
        @test get(r, k, NaN) ≈ exp atol=1e-8
    end
end

# ─── New Tests: Additional ProbLog Test Suite Coverage ─────────────────────

@testset "00_trivial_undefined_failed.pl" begin
    # :- unknown(fail) makes undefined atoms return 0 instead of error
    r = problog_query(":- unknown(fail). query(a).")
    @test r["a"] ≈ 0.0 atol=1e-10
end

@testset "00_trivial_undefined2_failed.pl" begin
    r = problog_query(":- unknown(fail). p :- a. query(p).")
    @test r["p"] ≈ 0.0 atol=1e-10
end

@testset "call_return_fail.pl — non-ground query" begin
    r = problog_query("""
        0.4::q(1,2).
        0.3::q(1,1).
        p(X) :- q(X,X).
        query(p(X)).
    """)
    @test r["p(1)"] ≈ 0.3 atol=1e-10
end

@testset "query_same.pl — same-variable binding" begin
    r = problog_query("""
        a(2,3).
        a(1,1).
        p(X) :- a(X,X).
        query(a(X,X)).
        query(p(X)).
    """)
    @test r["a(1,1)"] ≈ 1.0 atol=1e-10
    @test r["p(1)"] ≈ 1.0 atol=1e-10
end

@testset "negative_head_lits.pl — negative head literals" begin
    r = problog_query("""
        0.7::b.
        0.2::c.
        0.5::a :- b.
        0.5::\\+a :- c.
        0.5::d :- b.
        \\+d :- c.
        0.5::e :- b.
        1.0::\\+e :- c.
        query(a). query(d). query(e).
    """)
    @test r["a"] ≈ 0.315 atol=1e-10
    @test r["d"] ≈ 0.28 atol=1e-10
    @test r["e"] ≈ 0.28 atol=1e-10
end

@testset "bug_nonground.pl — equality unification" begin
    r = problog_query("""
        0.4::a(1). 0.5::a(2). 0.3::b(1). 0.6::b(2).
        0.1::c(1,2). 0.3::c(2,1).
        p(X, Y) :- a(X).
        p(X, Y) :- b(Y).
        p(X, Y) :- c(X, Y).
        q(Y) :- p(X, Y), X = 3.
        q(X, Y) :- p(X, Y).
        query(q(1)).
        query(q(1,2)).
    """)
    @test r["q(1)"] ≈ 0.3 atol=1e-10
    @test r["q(1,2)"] ≈ 0.784 atol=1e-10
end

@testset "bug_nonground_more.pl — unbound head variables" begin
    r = problog_query("""
        0.4::a(1). 0.5::a(2). 0.3::b(1). 0.6::b(2). 0.1::c(1,2).
        p(X, Y) :- a(X).
        p(X, Y) :- b(Y).
        p(X, Y) :- c(X, Y).
        p1(X) :- p(X, _).
        p2(X) :- p(_, X).
        p :- p(_, _).
        query(p(1,2)). query(p(2,1)). query(p(3,1)).
        query(p1(1)). query(p1(2)).
        query(p2(1)). query(p2(2)).
        query(p).
    """)
    @test r["p(1,2)"] ≈ 0.784 atol=1e-6
    @test r["p(2,1)"] ≈ 0.65 atol=1e-6
    @test r["p(3,1)"] ≈ 0.3 atol=1e-6
    @test r["p1(1)"] ≈ 0.8488 atol=1e-6
    @test r["p1(2)"] ≈ 0.86 atol=1e-6
    @test r["p2(1)"] ≈ 0.79 atol=1e-6
    @test r["p2(2)"] ≈ 0.892 atol=1e-6
    @test r["p"] ≈ 0.9244 atol=1e-6
end

@testset "non_ground_query.pl — non-ground queries with recursion" begin
    r = problog_query("""
        0.1::b(1). 0.2::b(2). 0.3::e(1). 0.4::e(3).
        d(1). d(2). d(3).
        a(X) :- b(2), c(X,Y).
        c(X,Y) :- c(X,Z), c(Z,Y).
        c(X,Y) :- d(X), d(Y).
        query(a(X)).
    """)
    @test r["a(1)"] ≈ 0.2 atol=1e-10
    @test r["a(2)"] ≈ 0.2 atol=1e-10
    @test r["a(3)"] ≈ 0.2 atol=1e-10
end

@testset "tasks/some_heads.pl" begin
    r = problog_query("""
        0.5::heads1.
        0.6::heads2.
        someHeads :- heads1.
        someHeads :- heads2.
        query(someHeads).
    """)
    @test r["someHeads"] ≈ 0.8 atol=1e-10
end

@testset "tasks/map_probabilistic_graph.pl — evidence conditioning" begin
    r = problog_query("""
        0.6::edge(1,2).
        0.1::edge(1,3).
        0.4::edge(2,5).
        0.3::edge(2,6).
        0.3::edge(3,4).
        0.8::edge(4,5).
        0.2::edge(5,6).
        path(X,Y) :- edge(X,Y).
        path(X,Y) :- edge(X,Z), Y \\== Z, path(Z,Y).
        query(edge(1,2)). query(edge(1,3)).
        evidence(path(1,6),true).
    """)
    @test r["edge(1,2)"] ≈ 0.991141 atol=1e-4
    @test r["edge(1,3)"] ≈ 0.112996 atol=1e-4
end

end
