:- module(interactive_search, []).

:- use_module(library(http/http_dispatch)).
:- use_module(library(http/http_parameters)).
:- use_module(library(http/http_request_value)).
:- use_module(library(http/html_write)).
:- use_module(library(http/http_wrapper)).
:- use_module(library(http/http_host)).
:- use_module(library(http/http_path)).
:- use_module(library(http/html_head)).
:- use_module(library(http/json)).
:- use_module(library(http/json_convert)).
:- use_module(library(semweb/rdf_db)).
:- use_module(library(semweb/rdfs)).
:- use_module(library(semweb/rdf_litindex)).
:- use_module(library(semweb/rdf_label)).
:- use_module(library(settings)).

:- http_handler(root(isearch), interactive_search_page, []).

:- setting(search:target_class, uri,
	   'http://purl.org/vocabularies/rma/Work',
	   'Default search target').
:- setting(search:term_limit, integer, 5,
	  'Maximum number of items initially shown in the term disambiguation list').
:- setting(search:relation_limit, integer, 5,
	  'Maximum number of relations initially shown').
:- setting(search:logo, atom,
	   'http://www.rijksmuseum.nl/images/logos/rijksmuseum-logo?medium',
	   'Src for an img shown as the on the page').

:- json_object
     prop(prop:atom, values:_),
     literal(literal:atom),
     literal(literal:_),
     type(type:atom, text:atom),
     lang(lang:atom, text:atom).

http:convert_parameter(json, Atom, Term) :-
	atom_json_term(Atom, JSON, []),
	json_to_prolog(JSON, Term).

interactive_search_page(Request) :-
	setting(search:target_class, TargetClass),
	http_parameters(Request,
			[ q(Query,
				[optional(true), description('Search query')]),
			  class(Class,
				[default(TargetClass), description('Target Class')]),
			  term(Terms,
			       [default([]), json,
				description('Disambiguation term')]),
			  relation(Relations,
				   [default([]), json,
				    description('Limit results by specific relation')]),
 			  filter(Filter,
				 [default([]), json,
				  description('Filters on the result set')]),
			  offset(Offset,
				[default(0), integer, description('Offset of the result list')]),
			  limit(Limit,
				[default(20), integer, description('Limit on the number of results')])
			]),
	(   var(Query)
	->  start_page(Class)
	;   result_page(Query, Terms, Class, Relations, Filter, Offset, Limit)
	).

%%	start_page(+Class)
%
%	Emit an html page with a search field

start_page(Class) :-
	reply_html_page(title('Search'),
			[  \html_requires(css('interactive_search.css')),
			   div(id(search),
			       \search_field('', Class))
			]).

%%	result_page(+Query, +Terms, +Class, +Relations, +Filter,
%%	+Offset, +Limit)
%
%	Emit an html page with a search field,
%	a left column with query suggestions, a body with the search
%	results and a right column with faceted filters.

result_page(Query, Terms, Class, Relations, Filter, Offset, Limit) :-

	% collect results
	R = result(S, Lit, T, Rel, Path),
	findall(R, search_result(Query, Class, S, Lit, T, Rel, Path), Results),

	% collect terms
	results_by_term(Results, ResultsByTerm),
	pairs_sort_by_result_count(ResultsByTerm, MatchingTerms),

	% filter the results
	(   Terms = []
	->  TermResults = Results
	;   findall(RT,
		    (	member(Term, Terms),
			memberchk(Term-RT, ResultsByTerm)
		    ),
		    RTs),
	    flatten(RTs, TermResults)
	),
       	filter_results(TermResults, Filter, FilteredResults),
	result_uris(FilteredResults, FilteredURIs),
	length(FilteredURIs, FilteredNumberOfResults),

	% collect relations
	results_by_relation(FilteredResults, ResultsByRelation),
	pairs_sort_by_result_count(ResultsByRelation, MatchingRelations),

	% filter by relation
	(   Relations = []
	->  RelationResults = FilteredResults
	;   findall(RR,
		    (	member(Relation, Relations),
			memberchk(Relation-RR, ResultsByRelation)
		    ),
		    RRs),
	    flatten(RRs, RelationResults)
	),

	% take limit and offset of results
	result_uris(RelationResults, ResultURIs),
	length(ResultURIs, NumberOfResults),
	list_offset(ResultURIs, Offset, OffsetResults),
	list_limit(OffsetResults, Limit, LimitResults, _),

	% collect facets
	facets(ResultURIs, Facets),

	% emit html page
	reply_html_page([ title(['Search results for ',Query])
 			],
			[  \html_requires(css('interactive_search.css')),
			   \html_requires('http://yui.yahooapis.com/3.1.1/build/yui/yui-min.js'),
			   div(id(logo), \logo),
			   div(id(search),
			       \search_field(Query, Class)
			      ),
			   div([id(left), class(column)],
			       [ div(class(toggle),
				     a([id(ltoggle),href('#'),
					onClick('javascript:bodyToggle(\'ltoggle\',\'lbody\', [\'<\',\'>\']);')
				 ], '<')),
				 div([class(body), id(lbody)],
				     [ \html_term_list(MatchingTerms, Terms)
				       %\html_related_term_list(RelatedTerms, Class)
				     ])
			       ]),
			   div(id(results),
			      [ div(class(header),
				    \html_relation_list(MatchingRelations, Relations,
							FilteredNumberOfResults)),
				\html_result_list(LimitResults),
				div(class(paginator),
				    \html_paginator(NumberOfResults, Offset, Limit)
				   )
			      ]),
			   div([id(right), class(column)],
			       [ div(class(toggle), a([id(rtoggle),href('#'),
					onClick('javascript:bodyToggle(\'rtoggle\',\'rbody\', [\'>\',\'<\']);')
				 ], '>')),
				 div([class(body), id(rbody)],
				     \html_facets(Facets, Filter)
				    )
			      ]),
			   script(type('text/javascript'),
				  [ \script_body_toggle,
				    'YUI().use("event", "json-stringify", "json-parse", function(Y) {\n',
				    \script_data(Query, Class, Terms, Relations, Filter),
				    \script_term_select(terms),
				    \script_relation_select(relations),
				    \script_facet_select(facets),
				    '});\n'
				  ])
			]).

result_uris(Results, URIs) :-
	findall(S, member(result(S, _,_,_,_), Results), URIs0),
	sort(URIs0, URIs).

results_by_term(Results, ResultsByTerm) :-
	Result = result(_, _, T, _, _),
	findall(T-Result, (member(Result, Results),
		      nonvar(T)
		     ),
		TermResults0),
	keysort(TermResults0, TermResults),
	group_pairs_by_key(TermResults, ResultsByTerm).

results_by_relation(Results, ResultsByRelation) :-
	Result = result(_, _, _, R, _),
	findall(R-Result, member(Result, Results), RelationResults0),
	keysort(RelationResults0, RelationResults),
	group_pairs_by_key(RelationResults, ResultsByRelation).


% collect related terms
	/*
	(   nonvar(Term)
	->  findall(P-T, related_term(Term, Class, T, P), PathTerms0),
	    sort(PathTerms0, PathTerms),
	    group_pairs_by_key(PathTerms, RelatedTerms)
	;   RelatedTerms = []
	),*/

	% coll

		 /*******************************
	         *	 collect results        *
		 *******************************/

%%	search_result(+Query, +Class, -S, -Lit, -Term, -Rel, -Path)
%
%	True if R is related to Query and of type Class.

search_result(Query, Class, S, _Lit, Query, P, [P,Query]) :-
	once(rdf(_,_,Query)),
	!,
	rdf(S, P, Query),
	instance_of_class(Class, S).
search_result(Query, Class, S, Lit, Term, Rel, Path) :-
	rdf_find_literals(case(Query), Literals),
	member(Lit, Literals),
	rdf(R, P, literal(Lit)),
	search_path(R, P, Class, S, Term, Rel, [P,literal(Lit)], Path).

search_path(S, P, Class, S, _Term, P, Path, Path) :-
	instance_of_class(Class, S),
	!.
search_path(Term, P, Class, S, Term, Rel, Path, [Rel,Term|Path]) :-
	rdfs_subproperty_of(P, rdfs:label),
	rdf(S, Rel, Term),
	instance_of_class(Class, S).


%%	filter_results(+Rs, +Filter, -Filtered)
%
%	Filtered contains the resources from Rs that pass Filter.

filter_results(Rs, [], Rs) :- !.
filter_results(Rs, Filter, FilteredResults) :-
	filter_to_goal(Filter, R, Goal),
	Result = result(R,_,_,_,_),
	findall(Result, (member(Result, Rs),
			 call(Goal)
			),
		FilteredResults).

filter_to_goal([], _, true).
filter_to_goal([prop(P, Values)|T], R, (Goal,Rest)) :-
	pred_filter(Values, P, R, Goal),
	filter_to_goal(T, R, Rest).

pred_filter([Value], P, R, Goal) :- !,
	Goal = rdf(R, P, Value).
pred_filter([Value|Vs], P, R, Goal) :-
	Goal =  (rdf(R, P, Value); Rest),
	pred_filter(Vs, P, R, Rest).

%%	related_term(+Resource, +Class, -Term)
%
%	Term is related to Resource.

related_term(R, Class, Term, P) :-
	related(R, Term, P),
	atom(Term),
	\+ equivalent_property(P),
	has_target(Term, Class).

has_target(Term, Class) :-
	rdf(Target, _, Term),
	instance_of_class(Class, Target).

related(S, O, P) :-
	rdf_eq(S, P0, V),
	(   O = V,
	    P = P0
	;   atom(V),
	    rdf_predicate_property(P0, rdf_object_branch_factor(BF)),
	    debug(related, '~w ~w', [P0, BF]),
	    BF < 10
	->  rdf_eq(O, P0, V),
	    O \== S,
	    P = V
	).
related(S, O, P) :-
	rdf_eq(O, P, S),
	rdf(P, owl:inverseOf, IP),
	\+ rdf_eq(S, IP, O).


%%	facets(+Results, -Facets)
%
%	Collect faceted properties of Results.

facets(Results, Facets) :-
	bagof(P-Values,
		bagof(V-Rs,
		      bagof(R,
			    ( member(R, Results),
			      resource_property(R, P, V)
			    ),
			    Rs
			   ),
		      Values
		     ),
		Facets).

resource_property(S, P, O) :-
	rdf(S, P, O).


rdf_eq(S, P, O) :-
	rdf(S, P, O).
%rdf_eq(S, P, O) :-
%	equivalent_property(R),
%	rdf(S, R, S1),
%	rdf(S1, P, O).

equivalent_property(P) :-
	rdf_equal(P, owl:sameAs).
equivalent_property(P) :-
	rdf_equal(P, skos:exactMatch).


		 /*******************************
		 *	 HTML result page	*
		 *******************************/
%%	logo
%
%	Emit a logo

logo -->
	{ setting(search:logo, Src),
	  http_location_by_id(interactive_search_page, Home)
	},
	html(a(href(Home), img(src(Src), []))).

%%	search_field(+Query, +Class)
%
%	Emit an html search field.

search_field(Query, Class) -->
	html(form([input([type(text), class(inp), name(q), value(Query)]),
		   input([type(hidden), name(class), value(Class)]),
		   input([type(submit), class(btn), value(search)])
		  ])).

%%	html_result_list(+Resources)
%
%	Emit HTML list with resources.

html_result_list([]) --> !.
html_result_list([R|Rs]) -->
	format_result(R),
	html_result_list(Rs).

format_result(R) -->
	html(div(class('result-item'),
		 [ div(class(thumbnail),
		       \result_image(R)),
		   div(class(text),
		       [ div(class(title),
			     a(href(R), \result_title(R))),
			 div(class(subtitle), \result_subtitle(R)),
			 div(class(description), \result_description(R))
		       ])
		 ])).

result_title(R) -->
	{ (   rdf_label(R, Lit)
	  ->  literal_text(Lit, Label)
	  ;   rdfs_label(R, Label)
	  )
	},
	html(Label).
result_subtitle(R) -->
	{ (   rdf_has(R, dc:creator, C)
	  ->  rdf_label(C, Lit),
	      literal_text(Lit, Creator)
	  ;   Creator = ''
	  ),
	  (   rdf_has(R, dc:date, D)
	  ->  literal_text(D, Date)
	  ;   Date = ''
	  )
	},
	html([Creator, ' (', Date, ')']).
result_description(R) -->
	{ rdf_has(R, dc:description, LitDesc),
	  literal_text(LitDesc, DescTxt),
	  truncate_atom(DescTxt, 200, Desc)
	},
	!,
	html(Desc).
result_description(_R) --> !.


result_image(R) -->
	{ rdf(Image, 'http://www.vraweb.org/vracore/vracore3#relation.depicts', R)
	},
	!,
	html(img(src(Image+'&resize100square'), [])).
result_image(_) --> !.

%%	html_paginator(+NumberOfResults, +Offset, +Limit)
%
%	Emit HTML paginator.

html_paginator(Total, _Offset, Limit) -->
	{ Total < Limit },
	!.

html_paginator(Total, Offset, Limit) -->
	{ http_current_request(Request),
	  request_url_components(Request, URLComponents),
	  Pages is ceiling(Total/Limit),
	  ActivePage is floor(Offset/Limit),
	  (   ActivePage < 9
	  ->  EndPage is min(10, Pages)
	  ;   EndPage is min(10+ActivePage, Pages)
	  ),
	  StartPage is max(0, EndPage-20),
	  (   select(search(Search0), URLComponents, Cs)
	  ->  delete(Search0, offset=_, Search)
	  ;   Search = Search0
	  ),
	  parse_url(URL, [search(Search)|Cs])
	},
 	prev_page(ActivePage, Limit, URL),
	html_pages(StartPage, EndPage, Limit, URL, ActivePage),
	next_page(ActivePage, Pages, Limit, URL).

prev_page(0, _, _) --> !.
prev_page(Active, Limit, URL) -->
	{ Offset is (Active-1)*Limit,
	  First = 0
	},
	html([span(class(first), a(href(URL+'&offset='+First), '<<')),
	      span(class(prev), a(href(URL+'&offset='+Offset), '<'))]).

next_page(_, 0, _, _) --> !.
next_page(Active, Last, _, _) -->
	{ Active is Last-1 },
	!.
next_page(Active, Last, Limit, URL) -->
	{ Offset is (Active+1)*Limit,
	  LastOffset is (Last-1)*Limit
	},
	html([span(class(next), a(href(URL+'&offset='+Offset), '>')),
	      span(class(last), a(href(URL+'&offset='+LastOffset), '>>'))]).

html_pages(N, N, _, _, _) --> !.
html_pages(N, Pages, Limit, URL, ActivePage) -->
	{ N1 is N+1,
	  Offset is N*Limit,
 	  (   N = ActivePage
	  ->  Class = active
	  ;   Class = ''
	  )
 	},
	html(span(class(Class), a(href(URL+'&offset='+Offset), N1))),
	html_pages(N1, Pages, Limit, URL, ActivePage).

%%	html_term_list(+Terms, +Query, +Class, +Selected)
%
%	Emit a list of terms matching the query.

html_term_list([], _) --> !.
html_term_list(Terms, Selected) -->
	{ setting(search:term_limit, Limit),
	  list_limit(Terms, Limit, TopN, Rest)
   	},
	html(div(id(terms),
		[ div(class(header), 'Did you mean?'),
		  div(class(items),
		      [ \resource_list(TopN, Selected),
			\resource_rest_list(Rest, term, Selected)
 		      ])
		])).

%%	html_relation_list(+Relations, +Selected, +NumberOfResults)
%
%	Emit html with matching relations.

html_relation_list([], _, NumberOfResults) --> !,
	html(div(id(relations),
		 div(class('relations-header'),
		     [NumberOfResults, ' result found']))).
html_relation_list(Relations, Selected, NumberOfResults) -->
	{ setting(search:relation_limit, Limit),
	  list_limit(Relations, Limit, TopN, Rest)
 	},
	html(div(id(relations),
		 [ div(class(header), [NumberOfResults, ' result found by: ']),
		   \resource_list(TopN, Selected),
		   \resource_rest_list(Rest, relation, Selected)
		 ])).

%%	html_facets(+Facets, +Query, +Class, +Term, +Filter)
%
%	Emit html with facet filters.

html_facets(Facets, Filter) -->
	html(div(id(facets),
		 \html_facets(Facets, 0, Filter))).

html_facets([], _, _) --> !.
html_facets([P-ValueResults|Fs], N, Filter) -->
	{ N1 is N+1,
	  rdfs_label(P, Label),
	  pairs_sort_by_result_count(ValueResults, Values),
	  list_limit(Values, 3, TopN, Rest),
	  (   memberchk(prop(P, Selected), Filter)
	  ->  true
	  ;   Selected = []
	  )
 	},
	html(div(class(facet),
		 [ div(class(header), Label),
		   div([title(P), class(items)],
		      [ \resource_list(TopN, Selected),
			\resource_rest_list(Rest, P+N, Selected)
		      ])
		 ])),
	html_facets(Fs, N1, Filter).

%%	resource_rest_list(+Pairs:count-resource, +Id, +Selected)
%
%	Emit HTML ul with javascript control to toggle display of body

resource_rest_list([], _, _) --> !.
resource_rest_list(Rest, Id, Selected) -->
	{ (   member(S, Selected),
	      memberchk(_-S, Rest)
	  ->  Display = 'display:block',
	      Label = 'less'
	  ;   Display = 'display:none',
	      Label = 'more'
	  )
	},
	html([ul([id(Id+body),
		  class('resource-list'),
		  style(Display)
		 ],
		 \resource_list(Rest, Selected)
		),
	      div(a([id(Id+toggle),href('#'),
		     onClick('javascript:bodyToggle(\''+Id+'toggle\',\''+Id+'body\',
						    [\'less\',\'more\']);')
		    ], Label))
	     ]).

%%	resource_list(+Pairs:count-resource, +Selected)
%
%	Emit list items.

resource_list([], _) --> !.
resource_list(Rs, Selected) -->
	html(ul(class('resource-list'),
		\resource_items(Rs, Selected))).

resource_items([], _) --> !.
resource_items([Count-R|T], Selected) -->
	{ (   R = literal(_)
	  ->  literal_text(R, Label)
	  ;   rdfs_label(R, Label)
	  )
	},
	resource_item(R, Label, Count, Selected),
 	resource_items(T, Selected).

resource_item(R, Label, Count, Selected) -->
	{ Selected = [],
	  resource_value(R, A)
	},
	!,
	html(li(title(A),
		\resource_item_content(Label, Count)
	       )).
resource_item(R, Label, Count, Selected) -->
 	 { memberchk(R, Selected),
	   resource_value(R, A),
	   !,
 	   http_absolute_location(css('checkbox_selected.png'), Img, [])
	},
	html(li([title(A), class(selected)],
		\resource_item_content(Label, Count, Img)
	       )).
resource_item(R, Label, Count, _Selected) -->
	{ http_absolute_location(css('checkbox_unselected.png'), Img, []),
	  resource_value(R, A)
	},
	html(li(title(A),
		  \resource_item_content(Label, Count, Img)
	       )).

resource_value(R, R) :- atom(R), !.
resource_value(Lit, S) :-
	prolog_to_json(Lit, JSON),
	with_output_to(string(S),
		       json_write(current_output, JSON, [])).

resource_item_content(Label, Count) -->
	html([ div(class(count), Count),
	       div(class('value-inner'),
		   \resource_label(Label))
	     ]).
resource_item_content(Label, Count, Img) -->
	html([ div(class(count), Count),
	       div(class('value-inner'),
		   [ div(class(checkbox), img(src(Img), [])),
		     \resource_label(Label)
 		   ])
	     ]).

resource_label(FullLabel) -->
	{ truncate_atom(FullLabel, 75, Label) },
	html(span([title(FullLabel), class(label)], Label)).

		 /*******************************
		 *	    javascript      	*
		 *******************************/

script_data(Query, Class, Terms, Relations, Filter) -->
	{ http_location_by_id(interactive_search_page, URL),
	  prolog_to_json(Filter, FilterJSON),
	  Params = json([url(URL),
			 q(Query),
			 class(Class),
			 terms(Terms),
			 relations(Relations),
			 filter(FilterJSON)
			]),
	  with_output_to(string(Data),
		       json_write(current_output, Params, []))
	},
 	html(\[
'var data = ',Data,';\n',
'var update = function(a, e) {
  for(var i=0; i<a.length; i++) {
     if(a[i]==e||a[i].literal==e.literal) { a.splice(i,1); return a; }
  }
  a.push(e);
  return a;
};\n',
'var updateFilter = function(a, p, v) {\n',
'  for(var i=0; i<a.length; i++) {
     if(a[i].prop==p) {
	var vs = update(a[i].values, v);
	if(vs.length==0) { a.splice(i,1) };
	return a;
      }
   }\n',
' a.push({prop:p, values:[v]});
  return a;
};\n',
'var makeParameters = function(o) {
  var s = "";\n',
' for(var key in o) {
    var v = o[key];\n',
'    if(v&&(v.constructor==Object||v.constructor==Array)) {
	s += key+"="+encodeURIComponent(Y.JSON.stringify(v))+"&";
     }\n',
'    else if(v) {
      s += key+"="+encodeURIComponent(v)+"&";
    }
  }\n',
'  return s;
};\n'
	      ]).

script_body_toggle -->
	html(\[
'function bodyToggle(toggleId, containerId, labels) {\n',
'    var elContainer = document.getElementById(containerId),
	 elToggle = document.getElementById(toggleId);\n',
'    if(elContainer.style.display === "none") {
         elContainer.style.display = "block";
	 elToggle.innerHTML = labels[0];
     }\n',
'    else {
	  elContainer.style.display = "none";
	   elToggle.innerHTML = labels[1];
     }',
'}\n'
	      ]).

script_term_select(Id) -->
	html(\[
'Y.delegate("click", function(e) {\n',
'  var value = e.currentTarget.get("title"),
       terms = update(data.terms, value),
       params = makeParameters({q:data.q,class:data.class,term:terms});\n',
'  window.location.href = data.url+"?"+params;\n',
'}, Y.one("#',Id,'"), "li");\n'
	      ]).

script_relation_select(Id) -->
	html(\[
'Y.delegate("click", function(e) {\n',
'  var value = e.currentTarget.get("title"),
       relations = update(data.relations, value),
       params = makeParameters({q:data.q,class:data.class,term:data.terms,relation:relations});\n',
' window.location.href = data.url+"?"+params;\n',
'}, Y.one("#',Id,'"), "li");\n'
	      ]).

script_facet_select(Id) -->
	html(\[
'Y.delegate("click", function(e) {\n',
'  var value = e.currentTarget.get("title");
   if(value.substr(0,1)=="{") {
      value = Y.JSON.parse(value);
   }\n',
'  var property = e.currentTarget.get("parentNode").get("parentNode").get("title"),
       filter = updateFilter(data.filter, property, value),
       params = makeParameters({q:data.q,class:data.class,term:data.terms,filter:filter});\n',
' window.location.href = data.url+"?"+params;\n',
'}, Y.one("#',Id,'"), "li");\n'
	      ]).

		 /*******************************
		 *	    utilities		*
		 *******************************/

%%	request_url_components(+Request, -URLComponents)
%
%	URLComponents contains all element in Request that together
%	create the request URL.

request_url_components(Request, [ protocol(http),
				  host(Host), port(Port),
				  path(Path), search(Search)
				]) :-
	http_current_host(Request, Host, Port,
			  [ global(false)
			  ]),
 	(   option(x_redirected_path(Path), Request)
	->  true
	;   option(path(Path), Request, /)
	),
	option(search(Search), Request, []).

%%	pairs_sort_by_result_count(+Pairs:key-list,
%%	-Sorted:listcount-key)
%
%	Sorted is a list with the keys of Pairs sorted by the number of
%	elements in the value list.

pairs_sort_by_result_count(Grouped, Sorted) :-
 	pairs_result_count(Grouped, Counted),
	keysort(Counted, Sorted0),
	reverse(Sorted0, Sorted).

pairs_result_count([], []).
pairs_result_count([Key-Results|T], [Count-Key|Rest]) :-
	(   Results = [H|_],
	    atom(H)
	->  length(Results, Count)
	;   result_uris(Results, URIs)
	),
	length(URIs, Count),
	pairs_result_count(T, Rest).


%%	list_offset(+List, +N, -SmallerList)
%
%	SmallerList starts at the nth element of List.

list_offset(L, N, []) :-
	length(L, Length),
	Length < N,
	!.
list_offset(L, N, L1) :-
	list_offset_(L, N, L1).

list_offset_(L, 0, L) :- !.
list_offset_([_|T], N, Rest) :-
	N1 is N-1,
	list_offset_(T, N1, Rest).

%%	list_limit(+List, +N, -SmallerList, -Rest)
%
%	SmallerList ends at the nth element of List.

list_limit(L, N, L, []) :-
	length(L, Length),
	Length < N,
	!.
list_limit(L, N, L1, Rest) :-
	list_limit_(L, N, L1, Rest).

list_limit_(Rest, 0, [], Rest) :- !.
list_limit_([H|T], N, [H|T1], Rest) :-
	N1 is N-1,
	list_limit_(T, N1, T1, Rest).

:- rdf_meta
    instance_of_class(r, r).

%%	instance_of_class(+Class, -R)
%
%	True if R is of rdf:type Class.

instance_of_class(Class, S) :-
	var(Class), !,
	rdf_subject(S).
instance_of_class(Class, S) :-
	rdf_equal(Class, rdfs:'Resource'), !,
	(   rdf(S, rdf:type, Class)
	;    \+ rdf(S, rdf:type, _)
	).
instance_of_class(Class, S) :-
	rdf(S, rdf:type, Class).
