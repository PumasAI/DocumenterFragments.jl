# separate file: the `public` keyword does not parse on Julia < 1.11
module FragmentPublic
public pfun
"The `pfun` function, deliberately not spliced into any page."
function pfun end
end
