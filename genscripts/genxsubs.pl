#!/usr/bin/perl
# Note: this isn't currently used due to problems
#
# Parses an XML file generated by `gccxml`,
# which is an XML representation of the C++ header file,
# to find all the methods of all the classes.
# Big thanks to Vladimir Olenin for pointing out `gccxml`,
# which made life much easier.
#
# For now, I first make a copy of original xs files to keep:
# cp -r xs xs-orig-copy
# plus backup other files:
# cp typemap typemap-orig-copy
# cp -r Ogre Ogre-orig-copy
# Then run the script:
# cp genscripts/Ogre.xml .
# ./genscripts/genxsubs.pl
# Then overwrite with xs files to keep:
# cp xs-orig-copy/* xs
# And regen docs:
# ./genscripts/gendocs.pl


# should look at GENERATE_PERLMOD option to doxygen

use strict;
use warnings;

use File::Copy;
use File::Slurp;
use File::Spec;
use List::Util qw(first);
use List::MoreUtils qw(any none);
use Storable;



warn " XXX: problem with AnimableValue constructor, arg type is 2 levels deep and not handled correctly\n";


# Change this to the directory where Ogre.h is located on your system.
# (maybe could get this from `pkg-config --cflags OGRE`)
my $INCDIR = File::Spec->catdir(File::Spec->rootdir, 'usr', 'include', 'OGRE');

my $XSDIR = File::Spec->catdir(File::Spec->curdir, 'xs');
my $PMDIR = File::Spec->catdir(File::Spec->curdir, 'Ogre');


# Classes to not generate for whatever reason
my %SKIPCLASS = (
    AlignedMemory => "C++ specific",
    CompositorChain => "inherits from a listener class (weird...)",
    IntersectionSceneQueryListener => "listener class",
    LogListener => "listener class",
    RaySceneQueryListener =>  "listener class",
    RenderQueueListener => "listener class",
    RenderTargetListener => "listener class",
    SceneQueryListener => "listener class",
    ShadowListener => "listener class",
    UTFString => "can be replaced by String (?)",
    VertexBoneAssignment_s => "struct",

    # causing too many problems
    MeshSerializerImpl_v1_1 => 'too much trouble',
    MeshSerializerImpl_v1_2 => 'too much trouble',
    MeshSerializerImpl_v1_3 => 'too much trouble',
    MeshSerializerImpl => 'too much trouble',
    MeshSerializer => 'too much trouble',

);


# Where parsed XML data is stored with Storable
my $STOREDXML = File::Spec->catfile(File::Spec->curdir, 'StoredXSUBs.dat');

# Don't change these, they're used as markers in the xs files
my $BEGINSTRING = 'GENERATED XSUBS BEGIN';
my $ENDSTRING = 'GENERATED XSUBS END';
my $BEGINBASES = 'GENERATED BASES BEGIN';
my $ENDBASES = 'GENERATED BASES END';
my $BEGINTM = 'GENERATED TYPEMAPS BEGIN';
my $ENDTM = 'GENERATED TYPEMAPS END';


# This is only used by print_xsubs and the subs it calls,
# to determine whether to print the method or not
# (i.e. its arg types and return types are supported)
my $PRINT_XSUB;

# This is just to keep track of how many xsubs are generated
my $XSUBCOUNT = 0;

# This keeps track of types for the typemap file
# (doesn't include enums, or specially-treated types like String or Real)
my %TYPEMAPS = ();


main();
exit();


sub main {
#    my $xmlfile = File::Spec->catfile(File::Spec->tmpdir, "Ogre.xml");
    my $xmlfile = File::Spec->catfile(File::Spec->curdir, "Ogre.xml");
    generate_xml($xmlfile);

    my ($ns, $classes, $methods, $types) = parse_xml($xmlfile);

    update_files($ns, $classes, $methods, $types);
}

sub update_files {
    my ($ns, $classes, $methods, $types) = @_;

    init_dirs($XSDIR, $PMDIR);

    my $cids = sorted_class_ids($ns, $classes);
    foreach my $cid (@$cids) {
        update_xs_file($classes, $cid, $methods, $types);
        update_pm_file($classes, $cid);
    }

    print STDERR "Generated $XSUBCOUNT xsubs\n";
}

sub init_dirs {
    foreach my $dir (@_) {
        unless (-d $dir) {
            mkdir($dir) || die "Couldn't mkdir '$dir': $!";
        }
    }
}

# update inheritance in .pm files
sub update_pm_file {
    my ($classes, $cid) = @_;
    my $class = $classes->{$cid};

    return unless exists $class->{bases};

    my $classname = $classes->{$cid}{demangled};
    (my $classtype = $classname) =~ s/^Ogre:://;

    if (exists $SKIPCLASS{$classtype}) {
        return;
    }

    my @basenames =
      grep { ! /<.+>/ }   # exclude template classes, STL types (vector, hash_map, etc.)
      map { $classes->{$_}{demangled} } split(/ /, $class->{bases});

    my $file = File::Spec->catfile($PMDIR, $classtype . '.pm');
    if (-f $file) {
        # see if we need to add begin/end strings
        my @lines = read_file($file);
        unless (first { /$BEGINBASES/ } @lines) {
            for (@lines) {
                if (/^package /) {
                    $_ .= "\n########## $BEGINBASES\n########## $ENDBASES\n\n";
                }
            }
        }

        write_file($file, \@lines);
    }
    else {
        create_pm_file($file, $classname);
    }


    # xxx: I need to find/make a module for this "generate" crap

    # backup old file
    my $oldfile = $file . '.bak~';
    unless (copy($file, $oldfile)) {
        warn "Couldn't copy '$oldfile' '$file': $!\n";
        return;
    }

    my $gensection = 0;

    open(my $newfh, "> $file") || die "Can't open file '$file': $!";
    open(my $oldfh, $oldfile)  || die "Can't open file '$oldfile': $!";
    while (<$oldfh>) {
        if (m{$BEGINBASES} && !$gensection) {
            $gensection = 1;
            print $newfh $_, $/;
        }

        elsif (m{$ENDBASES}) {
            # where the work actually is done,
            # updating the lines between the begin and end strings
            foreach my $basename (@basenames) {
                # Got a little carried away with std::exception here :)
                # and I don't know why some classes inherit from Listener classes!
                next if $basename =~ /^std::/ || $basename =~ /Listener$/;

                print $newfh "use $basename;\n";
                print $newfh "push \@${classname}::ISA, '$basename';\n";
            }

            print $newfh $/, $_;   # end string
            $gensection = 0;       # outta here
        }

        elsif ($gensection) {
            next;
        }

        else {
            print $newfh $_;
        }
    }

    if ($gensection) {
        die "No end string found in file '$file'\n";
    }

    close($oldfh);
    close($newfh);
}

sub create_pm_file {
    my ($file, $classname) = @_;

    my @lines = "package $classname;\n\n";
    push @lines, "use strict;\nuse warnings;\n\n";
    push @lines, "########## $BEGINBASES\n";
    push @lines, "########## $ENDBASES\n\n";
    push @lines, "1;\n\n__END__\n";
    write_file($file, \@lines);
}

sub update_xs_file {
    my ($classes, $cid, $methods, $types) = @_;
    my $class = $classes->{$cid}{demangled};

    if ($class =~ /^Ogre::([^:]+)$/) {
        my $classtype = $1;
        if (exists $SKIPCLASS{$classtype}) {
            warn "skipped class $classtype: $SKIPCLASS{$classtype}\n";
            return;
        }

        my $file = File::Spec->catfile($XSDIR, $classtype . '.xs');
        xs_file_init($file, $class);

        # find generated section, update
        update_xsubs($file, $classes, $cid, $methods, $types);
    }

    else {
        die "unsupported classname '$class'\n";
    }
}

sub update_xsubs {
    my ($newfile, $classes, $cid, $methods, $types) = @_;
    my $class = $classes->{$cid}{demangled};

    # backup old file
    my $oldfile = $newfile . '.bak~';
    unless (copy($newfile, $oldfile)) {
        warn "Couldn't copy '$oldfile' '$newfile': $!\n";
        return;
    }

    my $gensection = 0;

    open(my $newfh, "> $newfile") || die "Can't open file '$newfile': $!";
    open(my $oldfh, $oldfile)     || die "Can't open file '$oldfile': $!";
    while (<$oldfh>) {
        if (m{$BEGINSTRING} && !$gensection) {
            $gensection = 1;
            print $newfh $_, $/;
        }

        elsif (m{$ENDSTRING}) {
            # where the work actually is done,
            # updating the lines between the begin and end strings
            print_xsubs($newfh, $classes, $cid, $methods, $types);

            print $newfh $/, $_;
            $gensection = 0;
        }

        elsif ($gensection) {
            next;
        }

        else {
            print $newfh $_;
        }
    }

    if ($gensection) {
        die "No end string found in file '$newfile'\n";
    }

    close($oldfh);
    close($newfh);
}

sub print_xsubs {
    my ($fh, $classes, $cid, $methods, $types) = @_;

    my $oldfh = select($fh);

    my $class = $classes->{$cid};
    (my $classtype = $class->{demangled}) =~ s/^Ogre:://;

    my %methods_seen = ();

    my $methids = sorted_method_ids($class, $methods);
    foreach my $methid (@$methids) {
        $PRINT_XSUB = 1;     # innocent until proven guilty

        my $meth = $methods->{$methid};
        my $methname = $meth->{name};

        if (bad_method($classtype, $methname)) {    # GUILTY!
            $PRINT_XSUB = 0;
        }

        my @xsub = ();
        push @xsub, "## $meth->{demangled}";

        if ((my $count = method_count($class, $methods, $methname)) > 1) {
            push @xsub, "## overloaded: $count occurences";
        }

        push @xsub, xsub_return_type($meth, $classtype, $types, $classes);

        # xxx: need to handle default values
        push @xsub, xsub_signature($meth, $classtype);

        push @xsub, xsub_arg_types($meth, $types, $classes);

        # CODE
        # xxx: probably a bunch of cases to handle here,
        # including default values and overloaded methods


        # xxx: for now, generate only 1st of any overloaded methods
        $PRINT_XSUB = 0 if $methods_seen{$methname};

        # add a destructor if it's a constructor; also skip constructor
        # if it's abstract
        if ($methname eq $classtype) {
            $PRINT_XSUB = 0 if $class->{abstract};

            push @xsub, $/;
            push @xsub, 'void';
            push @xsub, $classtype . '::DESTROY()';

            if ($PRINT_XSUB) {
                $XSUBCOUNT++;
            }
        }

        foreach my $line (@xsub) {
            print "### " unless $PRINT_XSUB;
            print "$line\n";
        }
        print $/;

        if ($PRINT_XSUB) {
            $XSUBCOUNT++;
            $methods_seen{$methname}++;
        }
    }

    select($oldfh);
}

sub bad_method {
    my ($classtype, $methname) = @_;

    # some of these are just from not handling "const *" return values

    return 1 if
      # needs OUTLIST
      ($classtype eq 'Mesh' && $methname eq 'suggestTangentVectorBuildParams')
        or ($classtype eq 'HardwareBufferManager' && $methname eq 'getSingleton')
        or ($classtype eq 'VertexDeclaration' && $methname =~ /^((add|get|insert)Element|findElementBySemantic|)$/)
        or ($classtype eq 'SceneManagerEnumerator' && $methname eq 'getMetaData')
        or ($classtype eq 'RenderSystem' && $methname eq 'getCapabilities')
        or ($classtype eq 'AxisAlignedBox' && $methname eq 'getAllCorners')
        or ($classtype eq 'Image' && $methname eq 'getData')
        or ($classtype eq 'AutoParamDataSource' && ($methname =~ /^getCurrent/ or $methname eq 'getWorldMatrixArray'))
        or ($classtype =~ /^GpuProgram/ && $methname =~ /^get.*(Struct|Singleton)$/)
        or ($classtype eq 'Frustum' && ($methname eq 'getFrustumPlanes' or $methname eq 'getWorldSpaceCorners'))
        or ($classtype eq 'Exception' && $methname eq 'what')
        or ($classtype eq 'RenderQueueInvocationSequence' && $methname eq 'iterator')
        or ($methname =~ /^get.*Iterator$/)
        or ($methname =~ /Ptr$/);

    # skip these constructors
    return 1 if ($classtype eq $methname)
      and (
          $classtype eq 'FileStreamDataStream'
      );

    return 0;
}

# WelCoMe tO ThE uGLy
sub xsub_arg_types {
    my ($meth, $types, $classes) = @_;
    my @types = ();
    my @c_arg_prefixes = ();
    my @argnames = meth_argnames($meth);

    if (@argnames) {
        for my $i (0 .. $#{ $meth->{args} }) {
            my $c_arg_prefix = '';

            my $arg = $meth->{args}[$i];
            my $type = get_type($arg->{type}, $types, $classes);

            $type->{typename} =~ s/^Ogre:://;
            my $argtype = $type->{typename};

            # Exclude template classes, STL types (vector, hash_map, etc.);
            # also exclude "deeper" classes like SceneQuery::WorldFragment.
            # Enums are special because I prepended their classname, like OverlayElement__FooType.
            if ($argtype =~ /(<.+>|::)/ && $type->{label} ne 'Enumeration') {
                $argtype = "XXX: $type->{typename}";
                $PRINT_XSUB = 0;
            }

            elsif ($argtype eq 'Serializer__Endian') {
                $PRINT_XSUB = 0;
            }

            elsif ($argtype eq 'String') {
                # do nothing (hmm, would this be handled naturally by ReferenceType below?)

                # note: don't keep track of String in %TYPEMAPS
                # because it's treated specially in typemap
            }

            elsif ($argtype eq 'string') {
                $argtype = 'String';
            }

            elsif ($argtype eq '_Ios_Fmtflags') {
                $argtype = "XXX: $argtype";
                $PRINT_XSUB = 0;
            }

            elsif (@{ $type->{quals} }) {
                # note: CvQualifiedType => "const", ReferenceType => "&",
                #       PointerType => "*", ArrayType => "[]" ;
                # for example,
                # [class] Ogre::Radian [ReferenceType; CvQualifiedType]
                my @quals = @{ $type->{quals} };
                for (@quals) {
                    # make sure I know what all types there can be
                    die "what type? '$_'\n"
                      unless /^(Reference|CvQualified|Pointer|Array)Type$/;
                }

                # xxx: what about things like &bool or &int ?  typedef + typemap ?

                # single pointer (not pointer to pointer) - OGRE_STAR typemap
                if (grep({ $_ eq 'PointerType' } @quals) == 1) {
                    if (none { /^(Reference|Array)Type$/ } @quals) {
                        # special case for Degree and Radian
                        if ($type->{typename} =~ /^(Degree|Radian)$/) {
                            $type->{typename} = 'DegRad';
                        }

                        # xxx: there are only a few of these pointer types,
                        # postponing them for now
                        if ($argtype =~ /^(uint32|uint16|int|unsigned int|float|Real)$/) {
                            $argtype = "XXX: $type->{typename} *";
                            $PRINT_XSUB = 0;
                        }
                        else {
                            $argtype = "$type->{typename} *";
                            $TYPEMAPS{$argtype} = 'OGRE_STAR';
                        }
                    }
                    else {
                        $argtype = "XXX: [@quals] $type->{typename}";
                        $PRINT_XSUB = 0;
                    }
                }

                # reference parameter - OGRE_AMP typemap
                elsif (first { $_ eq 'ReferenceType' } @quals) {
                    if (none { /^(Pointer|Array)Type$/ } @quals) {
                        # special case for Degree and Radian
                        if ($type->{typename} =~ /^(Degree|Radian)$/) {
                            $type->{typename} = 'DegRad';
                        }


                        # postponing for now
                        if ($argtype =~ /(List|Ptr|VertexBoneAssignment)$/) {
                            $argtype = "XXX: $type->{typename} *";
                            $PRINT_XSUB = 0;
                        }
                        else {
                            $c_arg_prefix = '*';
                            #$argtype = $type->{typename};
                            #$TYPEMAPS{$argtype} = 'OGRE_AMP';
                            $argtype = "$type->{typename} *";
                            $TYPEMAPS{$argtype} = 'OGRE_STAR';
                        }
                    }
                    else {
                        $c_arg_prefix = '*';
                        $argtype = "XXX: [@quals] $type->{typename}";
                        $PRINT_XSUB = 0;
                    }
                }

                elsif (@quals == 1 && $quals[0] eq 'CvQualifiedType'
                         && ($type->{typename} =~ /^(Real|.*\bint|bool|ushort|size_t)$/
                               || $type->{label} =~ /^(Enumeration|Typedef)$/))
                {
                    $argtype = $type->{typename};


                    # note: not put in %TYPEMAPS because Real is special
                    # and the rest already have default typemaps
                }

                else {
                    $argtype = "XXX: [@quals] $type->{typename}";
                    $PRINT_XSUB = 0;
                }
            }

            # these can't be typemapped because of a conflict in Ogre and sys/types.h headers
            if ($argtype eq 'ushort') {
                $argtype = 'short unsigned int';
            }
            elsif ($argtype eq 'uint') {
                $argtype = 'unsigned int';
            }

            push @types, [$argtype, $argnames[$i]];
            push @c_arg_prefixes, $c_arg_prefix;
        }
    }

    my @ret = map { "    $_->[0]  $_->[1]" } @types;
    if (first { $_ ne '' } @c_arg_prefixes) {
        push @ret, "  C_ARGS:";

        my $args = '    '
          . join(', ', map { $c_arg_prefixes[$_] . $types[$_]->[1] } 0 .. $#types);
        push @ret, $args;
    }

    return @ret;
}

sub xsub_signature {
    my ($meth, $classtype) = @_;

    # these are "Pointer accessor for direct copying",
    # which I assume is unnecesary in Perl? In any case,
    # it's annoying to deal with Real* return type. :)
    $PRINT_XSUB = 0 if $meth->{name} eq 'ptr';

    my @argnames = meth_argnames($meth);
    return sprintf('%s::%s(%s)',
                   $classtype,
                   (($meth->{name} eq $classtype) ? 'new' : $meth->{name}),
                   join(', ', @argnames));
}

sub meth_argnames {
    my ($meth) = @_;

    my @argnames = ();

    if (exists $meth->{args}) {
        @argnames = map({
            my $arg = $meth->{args}[$_];
            (exists($arg->{name}) ? $arg->{name} : "arg$_")
        } 0 .. $#{ $meth->{args} });
    }

    return @argnames;
}

sub xsub_return_type {
    my ($meth, $classtype, $types, $classes) = @_;

    if (exists $meth->{returns}) {
        my $type = get_type($meth->{returns}, $types, $classes);
        # for classes, strip off leading Ogre
        $type->{typename} =~ s/^Ogre:://;

        # default return type
        my $rettype = $type->{typename};


        # xxx: still need to handle types like LightList,
        # which is typedef of vector<Light *>,
        # and iterators, and arrays, and pointers to arrays...


        # exclude template classes, STL types (vector, hash_map, etc.)
        # also exclude "deeper" classes like SceneQuery::WorldFragment
        if ($type->{typename} =~ /(<.+>|::)/) {
            $rettype = "XXX: $type->{typename}";
            $PRINT_XSUB = 0;
        }

        elsif ($type->{typename} eq 'String') {
            # do nothing
        }

        elsif ($type->{typename} eq 'string') {
            $rettype = 'String';
        }

        elsif ($rettype eq '_Ios_Fmtflags') {
            $rettype = "XXX: $rettype";
            $PRINT_XSUB = 0;
        }

        elsif (@{ $type->{quals} }) {
            # note: CvQualifiedType => "const", ReferenceType => "&",
            #       PointerType => "*", ArrayType => "[]" ;
            # for example,
            # [class] Ogre::Radian [ReferenceType; CvQualifiedType]
            my @quals = @{ $type->{quals} };
            for (@quals) {
                # make sure I know what all types there can be
                die "what type? '$_'\n"
                  unless /^(Reference|CvQualified|Pointer|Array)Type$/;
            }

            # single pointer (not pointer to pointer) - OGRE_STAR typemap
            if (grep({$_ eq 'PointerType'} @quals) == 1) {
                if (none { /^(Reference|Array)Type$/ } @quals) {
                    # note: not special on return
                    ## special case for Degree and Radian
                    #if ($type->{typename} =~ /^(Degree|Radian)$/) {
                    #    $type->{typename} = 'DegRad';
                    #}

                    # xxx: there are only a few of these pointer types,
                    # postponing them for now
                    if ($rettype =~ /^(uint32|uint16|int|unsigned int|float|Real)$/) {
                        $rettype = "XXX: $type->{typename} *";
                        $PRINT_XSUB = 0;
                    }
                    else {
                        $rettype = "$type->{typename} *";
                        $TYPEMAPS{$rettype} = 'OGRE_STAR';
                    }
                }
                else {
                    $rettype = "XXX: $type->{typename}";
                    $PRINT_XSUB = 0;
                }
            }

            # reference parameter - OGRE_AMP typemap
            elsif (first { $_ eq 'ReferenceType' } @quals) {
                if (none { /^(Pointer|Array)Type$/ } @quals) {
                    # note: not special on return
                    ## special case for Degree and Radian
                    #if ($type->{typename} =~ /^(Degree|Radian)$/) {
                    #    $type->{typename} = 'DegRad';
                    #}

                    $rettype = $type->{typename};
                    $TYPEMAPS{$rettype} = 'OGRE_AMP';
                }
                else {
                    $rettype = "XXX: [@quals] $type->{typename}";
                    $PRINT_XSUB = 0;
                }
            }

            else {
                $rettype = "XXX: [@quals] $type->{typename}";
                $PRINT_XSUB = 0;
            }
        }

        if ($rettype eq 'ushort') {
            $rettype = 'short unsigned int';
        }
        elsif ($rettype eq 'uint') {
            $rettype = 'unsigned int';
        }

        return $rettype;
    }

    elsif ($meth->{name} eq $classtype) {     # constructor
        return "$classtype *";
    }

    else {
        return 'void';
    }
}

# note: this returns a hashref, not a string
sub get_type {
    my ($typeid, $types, $classes, @types_pointed) = @_;

    my %ret = ();
    $ret{quals} = [ @types_pointed ];

    # Class or Struct
    if (exists $classes->{$typeid}) {
        $ret{label} = $classes->{$typeid}{label};
        $ret{typename} = $classes->{$typeid}{demangled};
        return \%ret;
    }

    if (exists $types->{$typeid}) {
        $ret{label} = $types->{$typeid}{label};

        if ($ret{label} =~ /^(FundamentalType|Typedef|Enumeration)$/) {
            $ret{typename} = $types->{$typeid}{name};

            if ($ret{label} eq 'Enumeration') {
                my $context_type = $types->{ $types->{$typeid}{context} }
                  || $classes->{ $types->{$typeid}{context} };
                my $context_name = defined($context_type)
                  ? $context_type->{name}
                  : 'Ogre';
                if (defined($context_name) && $context_name ne 'Ogre') {
                    $ret{typename} =  $context_name . '__' . $ret{typename};
                }
            }
        }

        elsif ($ret{label} eq 'FunctionType') {
            # $ret{typename} = $ret{label};
            die "wow, a $ret{label}!\n";
        }

        # anything that points to another type gets putshed on a stack
        elsif (exists($types->{$typeid}{type}) && $types->{$typeid}{type} =~ /^_[\da-z]+$/) {
            push @types_pointed, $ret{label};
            return get_type($types->{$typeid}{type}, $types, $classes, @types_pointed)
        }

        else {
            die "what type is this? '$typeid'\n";
        }

        return \%ret;
    }

    die "unresolved type ID '$typeid' (@types_pointed)\n";
}

sub xs_file_init {
    my ($file, $class) = @_;

    unless (-f $file) {
        open(my $fh, "> $file") || die "Can't create xs file '$file': $!";
        print $fh "MODULE = Ogre\tPACKAGE = $class\n\n";
        close($fh);
    }

    my @lines = read_file($file);
    foreach my $line (@lines) {
        return 1 if $line =~ /$ENDSTRING/;
    }

    # Didn't find begin string,
    # but don't want to wipe out manually wrapped methods,
    # so add the begin/end strings to the bottom
    if (write_file($file, {append => 1},
                   "\n\n########## $BEGINSTRING\n\n########## $ENDSTRING\n"))
    {
        return 1;
    }

    return 0;
}

sub generate_xml {
    my ($xmlfile) = @_;

    return if -r $xmlfile;

    my $orig_dir = getcwd();
    chdir($INCDIR) || die "Can't chdir to '$INCDIR': $!";

    # xxx: I'm not even sure gccxml is available on non-unix systems...

    my @args = ('gccxml', 'Ogre.h', qq{-fxml=$xmlfile});
    print STDERR "Generating XML... \n";
    print STDERR qq{(note: an error about missing OgrePrerequisites is "normal")\n};
    # rather than check system's return value,
    # which would normally make sense....
    # check for the existence of the XML file
    system(@args);
    unless (-r $xmlfile && -s _) {
        die "system @args failed: $?";
    }
    print "done\n";

    chdir($orig_dir) || die "Can't chdir to '$orig_dir': $!";
}

# You'd think I'd use a SAX parser, but nooo....
sub parse_xml {
    my ($file) = @_;

    if (-f $STOREDXML) {   # stupid that you have to check the file exists..
        my $parsed_xml = retrieve($STOREDXML);
        if (defined $parsed_xml) {
            return @$parsed_xml{qw(ns classes methods types)};
        }
    }

    my %ns = ();
    my %classes = ();
    my %methods = ();
    my $method_id = '';
    my %types = ();
    my $functiontype_id = '';

    print STDERR "Parsing XML... ";

    open(my $xml, $file) || die "Can't open '$file': $!";
    while (<$xml>) {
        if (m{<Namespace }) {
            my $attr = get_attrs($_);

            # I only get the Ogre namespace
            # (there are two other *Command namespaces,
            # but I can do them manually if necessary)
            next unless exists($attr->{demangled}) && $attr->{demangled} eq 'Ogre';

            $ns{$attr->{id}}{demangled} = $attr->{demangled};

            # members is a list of 'id' numbers
            # which point to any member of the namespace ('Ogre').
            # This is just used to narrow down the ids so they
            # don't include any non-members.
            foreach my $member (map { split } $attr->{members}) {
                $ns{$attr->{id}}{members}{$member}++;
            }
        }

        elsif (m{<(Class|Struct) }) {
            my $label = $1;
            my $attr = get_attrs($_);

            # To resolve some types, we apparently need Classes outside the Ogre namespace
            # (e.g. class type_info....), so I commented out these `next'

            # next unless exists($attr->{demangled}) && $attr->{demangled} =~ /^Ogre/;

            # these are usually iterator or template classes,
            # so I skip them (maybe shouldn't skip the template ones)
            # next if $attr->{demangled} =~ /_|&/;

            # an empty class? useless
            # next unless exists($attr->{members});

            $classes{$attr->{id}}{label} = $label;
            $classes{$attr->{id}}{demangled} = $attr->{demangled};
            $classes{$attr->{id}}{name} = $attr->{name};

            # like Namespace, this members is a list of ids
            $classes{$attr->{id}}{members} = {};
            $attr->{members} = [] unless exists $attr->{members};     # ugh
            foreach my $member_id (map { split } $attr->{members}) {
                $classes{$attr->{id}}{members}{$member_id}++;
            }

            # what it inherits from
            # xxx: need to be added to .pm files
            if (exists($attr->{bases}) && $attr->{bases}) {
                my $bases = $attr->{bases};
                $bases =~ s/(?:^\s+|\s+$)//g;    # strip off leading/trailing space
                $classes{$attr->{id}}{bases} = $attr->{bases};
            }

            # some classes can't have their constructors called,
            # so we'll skip those
            $classes{$attr->{id}}{abstract} = exists($attr->{abstract})
              ? $attr->{abstract}
              : 0;
        }

        elsif (m{<(\w+Type|Typedef|Enumeration) }) {
            my $label = $1;
            my $attr = get_attrs($_);

            $types{$attr->{id}}{label} = $label;

            # Enumeration doesn't have a type attr
            $types{$attr->{id}}{type} = $attr->{type} if exists($attr->{type});

            # Typedef, Enumeration
            if (exists $attr->{name}) {
                my $name = $attr->{name};
                # note: there's one class enum without a name,
                # which gccxml calls "._100"
                # (has one value, Ogre::PatchSurface::AUTO_LEVEL)
                if ($name eq '._100') {
                    $name = 'PatchAutoLevelType';
                }
                $types{$attr->{id}}{name} = $name;
            }

            # FunctionType
            if ($label eq 'FunctionType') {
                $functiontype_id = $attr->{id};
            }

            if ($label eq 'Enumeration') {
                $types{$attr->{id}}{context} = $attr->{context};
            }
        }

        elsif (m{<(Method|Constructor) }) {
            my $label = $1;
            my $attr = get_attrs($_);

            # skip protected and private ones...
            # (is it correct to skip protected?)
            next unless exists($attr->{name});
            next if $attr->{name} =~ /^_/;
            next if exists($attr->{access})
              && ($attr->{access} eq 'private' or $attr->{access} eq 'protected');

            # these seem to be C++ default constructors, so skipping
            if ($label eq 'Constructor') {
                next if exists($attr->{artificial}) && $attr->{artificial};
            }

            $method_id = $attr->{id};
            $methods{$method_id}{demangled} = $attr->{demangled};

            if (exists($attr->{access})) {
                $methods{$method_id}{access} = $attr->{access};
            }

            if (exists($attr->{returns})) {
                $methods{$method_id}{returns} = $attr->{returns};
            }

            $methods{$method_id}{name} = $attr->{name};
            $methods{$method_id}{const} = exists($attr->{const}) ? 'yes' : 'no';
            $methods{$method_id}{static} = exists($attr->{static}) ? 'yes' : 'no';

            # empty tag
            if (m{/>$}) {
                # there won't be a separate end tag, so no Arguments
                $method_id = '';
            }
        }

        elsif ($method_id or $functiontype_id) {
            if (m{</(Method|Constructor)}) {
                # done with that method
                $method_id = '';
            }

            elsif (m{</FunctionType}) {
                $functiontype_id = '';
            }

            elsif (m{<Argument }) {
                my $attr = get_attrs($_);
                my %arg = (
                    type => $attr->{type},    # an ID
                );
                $arg{name} = $attr->{name} if exists($attr->{name});   # not for FunctionType,
                $arg{default} = $attr->{default} if exists($attr->{default});

                if ($method_id) {
                    push @{ $methods{$method_id}{args} }, \%arg;
                }
                elsif ($functiontype_id) {
                    push @{ $types{$functiontype_id}{args} }, \%arg;
                }
            }
        }

        else {
            # print STDERR "WTF: $_\n" if /Typedef/;
        }
    }
    close($xml);

    print STDERR "done.\n";

    my $storing = {ns => \%ns, classes => \%classes, methods => \%methods, types => \%types};
    store($storing, $STOREDXML) or die "Couldn't store in '$STOREDXML'\n";

    return(\%ns, \%classes, \%methods, \%types);
}

sub xml_unescape {
    for ($_[0]) {
        s{&lt;}{<}g;
        s{&gt;}{>}g;
        s{&amp;}{&}g;
        s{&quot;}{"}g;
        s{&apos;}{'}g;
    }
    return $_[0];
}

sub get_attrs {
    my %attrs = map { xml_unescape($_) } $_[0] =~ / (\w+)="([^"]*)"/g;
    return \%attrs;
}


sub sorted_class_ids {
    my ($ns, $classes) = @_;

    # note: there's really only one namespace
    foreach my $nsid (sort keys %$ns) {
        # class ids schwartzed by class name
        # and skipping ones not in the namespace
        my @cids = map {$_->[0]}
          sort {$a->[1] cmp $b->[1]}
          map {[$_, $classes->{$_}{demangled}]}
          grep { exists $ns->{$nsid}{members}{$_} }
          keys %$classes;

        return \@cids;
    }
}

sub sorted_method_ids {
    my ($class, $methods) = @_;

    # class method ids schwartzed by name,
    # by happy coincidence this usually puts constructors first
    my @methids = map {$_->[0]}
      sort {$a->[1] cmp $b->[1]}
      map {[$_, $methods->{$_}->{name}]}
      grep { exists $methods->{$_} }
      keys %{ $class->{members} };

    return \@methids;
}

# number of times methods are in the class (for overloaded methods)
sub method_count {
    my ($class, $methods, $method) = @_;

    my %names = ();
    foreach my $id (keys %{ $class->{members} }) {
        next unless exists $methods->{$id};

        $names{$methods->{$id}->{name}}++;
    }

    if (defined $method) {
        if (exists $names{$method}) {
            return $names{$method};
        }
        else {
            return 0;
        }
    }
    else {
        return \%names;
    }
}