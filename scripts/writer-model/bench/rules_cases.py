"""Held-out cases for VoiceIQ Writer's custom writing rules and spelling
variants, in the format of cases.py plus the user's settings:

rules:     the custom writing rules text, or null
spelling:  an English spelling variant name ("English (UK)"), or null

rule_applied cases give a rule something to change, rule_not_applied cases
carry a rule with nothing to act on (or a word in another sense), and
spelling cases set only the variant. Written by hand; none come from the
training inputs, and filter.py and holdout.py keep training rows away from them.
"""
import json

SIGN = "Sign off emails with:\nBest,\nPriya"
C = []


def case(id, category, raw, reference, rules=None, spelling=None, must=(), must_not=(), regex=(), not_regex=()):
    C.append(dict(id=id, category=category, rules=rules, spelling=spelling, raw=raw, reference=reference,
                  must=list(must), must_not=list(must_not), regex=list(regex), not_regex=list(not_regex)))


# Rule applies.
case("oxford_snacks", "rule_applied", "please bring snacks drinks and napkins to the meetup on Thursday",
     "Please bring snacks, drinks, and napkins to the meetup on Thursday.",
     rules="Always use the Oxford comma.", must=["snacks, drinks, and napkins"])
case("oxford_topics", "rule_applied", "the report covers revenue costs and hiring plans for next quarter",
     "The report covers revenue, costs, and hiring plans for next quarter.",
     rules="- use the oxford comma in every series", must=["revenue, costs, and hiring plans"])
case("small_numbers_words", "rule_applied", "we have three open bugs and twelve tickets in the backlog",
     "We have three open bugs and 12 tickets in the backlog.",
     rules="Write numbers under ten as words.", must=["three open bugs", "12 tickets"], must_not=["3 open"])
case("small_numbers_run", "rule_applied", "I ran five kilometers this morning and it took about twenty eight minutes",
     "I ran five kilometers this morning, and it took about 28 minutes.",
     rules="Numbers one to nine: spell them out. 10 and up: digits.", must=["five kilometers", "28 minutes"])
case("signoff_added", "rule_applied",
     "hi Daniel thanks for sending the contract over I've signed it and attached it here let me know if you need anything else",
     "Hi Daniel,\n\nThanks for sending the contract over. I've signed it and attached it here. Let me know if you need anything else.\n\nBest,\nPriya",
     rules=SIGN, regex=[r"Best,\s*\nPriya\s*$"])
case("no_exclamation", "rule_applied", "wow that's amazing news congratulations to the whole team we did it",
     "Wow, that's amazing news. Congratulations to the whole team. We did it.",
     rules="No exclamation marks, ever.", must=["Congratulations"], not_regex=["!"])
case("customers_word", "rule_applied",
     "our clients have been asking for a dark mode so let's prioritize it for the next release",
     "Our customers have been asking for a dark mode, so let's prioritize it for the next release.",
     rules="Use 'customers', not 'clients'.", must=["customers"], must_not=["clients"])
case("dash_lists", "rule_applied",
     "a few things for tomorrow first send the invoice to Acme second update the roadmap doc and third book flights for the offsite",
     "A few things for tomorrow:\n\n- Send the invoice to Acme.\n- Update the roadmap doc.\n- Book flights for the offsite.",
     rules="Format lists with dashes, not numbers.", regex=[r"(?m)^- .*\n\n?- .*\n\n?- "], not_regex=[r"(?m)^\d+[.)] "])
case("ok_not_okay", "rule_applied", "so the build passed and I think we're okay to ship on Monday",
     "So the build passed, and I think we're OK to ship on Monday.",
     rules="Write OK, not okay.", must=["OK to ship"], must_not=["okay"])
case("product_name", "rule_applied", "I've been using voice iq for dictation and it's way faster than typing",
     "I've been using VoiceIQ for dictation, and it's way faster than typing.",
     rules="Our product is spelled VoiceIQ (capital V, I and Q).", must=["VoiceIQ"])
case("time_24h", "rule_applied", "let's meet at three thirty in the afternoon on Friday",
     "Let's meet at 15:30 on Friday.", rules="Use 24-hour time.", must=["15:30"])
case("date_ddmm", "rule_applied", "the deadline is March fourth twenty twenty seven",
     "The deadline is 04/03/2027.", rules="Dates: DD/MM/YYYY", must=["04/03/2027"])
case("percent_word", "rule_applied", "conversion went up by twelve percent last week",
     "Conversion went up by 12 percent last week.", rules="Spell out percent instead of using the % sign.",
     regex=["(12|twelve) percent"], must_not=["%"])
case("no_contractions", "rule_applied",
     "I don't think we can make it on time but we'll try our best and I'll let you know",
     "I do not think we can make it on time, but we will try our best, and I will let you know.",
     rules="Don't use contractions in anything I write.", must=["do not think"],
     must_not=["don't", "we'll", "I'll"])
case("team_name", "rule_applied", "infra is going to handle the database migration this weekend",
     "The platform team is going to handle the database migration this weekend.",
     rules="Always call our team 'the platform team', never 'infra'.", must=["platform team"], must_not=["infra"])
case("rupee_symbol", "rule_applied", "the hotel costs four thousand five hundred rupees a night",
     "The hotel costs ₹4,500 a night.", rules="Write rupee amounts with the ₹ symbol.", must=["₹4,500"])
case("metric_abbrev", "rule_applied", "the box weighs about twelve kilograms so we'll need two people to carry it",
     "The box weighs about 12 kg, so we'll need two people to carry it.",
     rules="Abbreviate metric units (km, kg, cm).", must=["12 kg"], must_not=["kilograms"])
case("checkbox_todos", "rule_applied", "things to do today call the bank renew my passport and pick up the dry cleaning",
     "Things to do today:\n\n- [ ] Call the bank\n- [ ] Renew my passport\n- [ ] Pick up the dry cleaning",
     rules="When I list tasks, make each one a checkbox: - [ ] task", regex=[r"(?m)^- \[ \] .*\n\n?- \[ \] .*\n\n?- \[ \] "])
case("multi_rules", "rule_applied", "great news we hired three engineers two designers and a product manager this month",
     "Great news. We hired three engineers, two designers, and a product manager this month.",
     rules="1. Always use the Oxford comma.\n2. Write numbers under ten as words.\n3. No exclamation marks.",
     must=["three engineers", "two designers, and a product manager"], not_regex=["!"])
case("rule_and_spelling", "rule_applied", "our clients love the new color scheme on the dashboard",
     "Our customers love the new colour scheme on the dashboard.",
     rules="use customers instead of clients", spelling="English (UK)", must=["customers", "colour"],
     must_not=["clients", "color "])

# Rule present, nothing in the dictation for it to change.
case("signoff_chat", "rule_not_applied", "hey can you push the fix before lunch",
     "Hey, can you push the fix before lunch?", rules=SIGN, must_not=["Best", "Priya"], regex=[r"\?$"])
case("small_numbers_big", "rule_not_applied", "we sold fifteen hundred units in the first week",
     "We sold 1,500 units in the first week.", rules="Write numbers under ten as words.", must=["1,500 units"],
     must_not=["fifteen hundred"])
case("dash_lists_prose", "rule_not_applied", "I checked the logs and then restarted the server and now it seems fine",
     "I checked the logs and then restarted the server, and now it seems fine.",
     rules="Format lists with dashes, not numbers.", must=["restarted the server"], not_regex=[r"(?m)^- "])
case("email_client", "rule_not_applied", "my email client keeps freezing whenever I open a big attachment",
     "My email client keeps freezing whenever I open a big attachment.", rules="Use 'customers', not 'clients'.",
     must=["email client"], must_not=["customer"])
case("oxford_two_items", "rule_not_applied", "bring your laptop and your charger to the workshop",
     "Bring your laptop and your charger to the workshop.", rules="Always use the Oxford comma.",
     must=["laptop and your charger"])
case("no_exclamation_question", "rule_not_applied", "can you believe the release is finally out",
     "Can you believe the release is finally out?", rules="No exclamation marks, ever.", regex=[r"\?$"],
     not_regex=["!"])
case("date_rule_no_date", "rule_not_applied", "let's push the meeting to next week since half the team is out",
     "Let's push the meeting to next week since half the team is out.", rules="Dates: DD/MM/YYYY",
     must=["next week"], not_regex=[r"\d{2}/\d{2}"])
case("time_rule_no_time", "rule_not_applied", "the train leaves early so let's meet at the station",
     "The train leaves early, so let's meet at the station.", rules="Use 24-hour time.", must=["at the station"],
     not_regex=[r"\d{1,2}:\d{2}"])
case("code_rule_personal_note", "rule_not_applied", "remind me to call the plumber after dinner tonight",
     "Remind me to call the plumber after dinner tonight.",
     rules="When I dictate code, use snake_case for variable names.", must=["call the plumber after dinner tonight"],
     must_not=["_"])
case("contractions_none", "rule_not_applied", "please send the report by Friday",
     "Please send the report by Friday.", rules="Don't use contractions in anything I write.",
     must=["Please send the report by Friday."])
case("question_not_answered", "rule_not_applied", "what's the capital of Australia again",
     "What's the capital of Australia again?",
     rules="Always use the Oxford comma.\nKeep my sentences short.", regex=[r"\?$"], must_not=["Canberra"])
case("checkbox_status", "rule_not_applied", "the migration finished overnight and all the tests are green",
     "The migration finished overnight, and all the tests are green.",
     rules="When I list tasks, make each one a checkbox: - [ ] task", must=["tests are green"],
     not_regex=[r"\[ \]"])

# Spelling variant.
case("uk_colour", "spelling", "I love the color of the new logo and the way the team organized the launch",
     "I love the colour of the new logo and the way the team organised the launch.", spelling="English (UK)",
     must=["colour", "organised"])
case("uk_centre", "spelling", "we're meeting at the community center at nine and then heading to the theater",
     "We're meeting at the community centre at 9 and then heading to the theatre.", spelling="English (UK)",
     must=["centre", "theatre"])
case("au_favourite", "spelling", "my favorite part of the trip was traveling along the coast",
     "My favourite part of the trip was travelling along the coast.", spelling="English (Australia)",
     must=["favourite", "travelling"])
case("ca_neighbour", "spelling", "the color of our neighbor's fence is driving me nuts",
     "The colour of our neighbour's fence is driving me nuts.", spelling="English (Canada)",
     must=["colour", "neighbour"])
case("in_behaviour", "spelling", "please check the behavior of the search page on older phones",
     "Please check the behaviour of the search page on older phones.", spelling="English (India)",
     must=["behaviour"])
case("us_color", "spelling", "the colour of the theatre seats was lovely", "The color of the theater seats was lovely.",
     spelling="English (US)", must=["color", "theater"])
case("uk_unchanged", "spelling", "can you send me the notes from today's call",
     "Can you send me the notes from today's call?", spelling="English (UK)",
     must=["Can you send me the notes from today's call?"])
case("uk_date", "spelling", "the launch is on March fifth so let's lock the copy by the first",
     "The launch is on 5 March, so let's lock the copy by the 1st.", spelling="English (UK)",
     regex=[r"5(th)? March"])
case("automatic_keeps_us", "spelling", "I love the color of the new logo and how organized the page feels",
     "I love the color of the new logo and how organized the page feels.", must=["color", "organized"])

if __name__ == "__main__":
    with open("rules_cases.jsonl", "w") as f:
        for c in C:
            f.write(json.dumps(c, ensure_ascii=False) + "\n")
    print(len(C), "cases")
