# --
# Kernel/System/CloneDB/Backend.pm - Interface for CloneDB backends
# Copyright (C) 2001-2015 OTRS AG, http://otrs.com/
# --
# This software comes with ABSOLUTELY NO WARRANTY. For details, see
# the enclosed file COPYING for license information (AGPL). If you
# did not receive this file, see http://www.gnu.org/licenses/agpl.txt.
# --

package Kernel::System::CloneDB::Backend;

use strict;
use warnings;

use Scalar::Util qw(weaken);
use Kernel::System::VariableCheck qw(:all);

our @ObjectDependencies = (
    'Kernel::Config',
    'Kernel::System::DB',
    'Kernel::System::Encode',
    'Kernel::System::Log',
    'Kernel::System::Main',
    'Kernel::System::Package',
    'Kernel::System::Time',
    'Kernel::System::XML',
);

=head1 NAME

Kernel::System::CloneDB::Backend

=head1 SYNOPSIS

DynamicFields backend interface

=head1 PUBLIC INTERFACE

=over 4

=cut

=item new()

create a CloneDB backend object

    use Kernel::System::ObjectManager;
    local $Kernel::OM = Kernel::System::ObjectManager->new();

    my $CloneDBObject = $Kernel::OM->Get('Kernel::System::CloneDB::Backend');

=cut

sub new {
    my ( $Type, %Param ) = @_;

    # allocate new hash for object
    my $Self = {};
    bless( $Self, $Type );

    #
    # OTRS stores binary data in some columns. On some database systems,
    #   these are handled differently (data is converted to base64-encoding before
    #   it is stored. Here is the list of these columns which need special treatment.
    $Self->{BlobColumns} = $Kernel::OM->Get('Kernel::Config')->Get('CloneDB::BlobColumns');

    $Self->{CheckEncodingColumns} = $Kernel::OM->Get('Kernel::Config')->Get('CloneDB::CheckEncodingColumns');

    # create all registered backend modules
    for my $DBType (qw(mssql mysql oracle postgresql)) {

        my $BackendModule = 'Kernel::System::CloneDB::Driver::' . $DBType;

        # check if database backend exists
        if ( !$Kernel::OM->Get('Kernel::System::Main')->Require($BackendModule) ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Can't load Clone DB backend module for DBMS $DBType!",
            );
            return;
        }

        $Kernel::OM->ObjectsDiscard(
            Objects => [$BackendModule],
        );

        $Kernel::OM->ObjectParamAdd(
            $BackendModule => {
                BlobColumns          => $Self->{BlobColumns},
                CheckEncodingColumns => $Self->{CheckEncodingColumns},
            },
        );

        # create a backend object
        my $BackendObject = $Kernel::OM->Get($BackendModule);

        if ( !$BackendObject ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Couldn't create a backend object for DBMS $DBType!",
            );
            return;
        }

        # remember the backend object
        $Self->{ 'CloneDB' . $DBType . 'Object' } = $BackendObject;
    }

    return $Self;
}

=item CreateTargetDBConnection()

creates the target db object.

    my $Success = $BackendObject->CreateTargetDBConnection(
        TargetDBSettings             => $TargetDBSettings, # a hash refs including target DB settings
    );

=cut

sub CreateTargetDBConnection {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TargetDBSettings)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    # check TargetDBSettings (internally)
    for my $Needed (
        qw(TargetDatabaseHost TargetDatabase TargetDatabaseUser TargetDatabasePw TargetDatabaseType)
        )
    {
        if ( !$Param{TargetDBSettings}->{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed in TargetDBSettings!"
            );
            return;
        }
    }

    # set the clone db specific backend
    my $CloneDBBackend = 'CloneDB' . $Param{TargetDBSettings}->{TargetDatabaseType} . 'Object';

    if ( !$Self->{$CloneDBBackend} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Backend $Param{TargetDBSettings}->{TargetDatabaseType} is invalid!"
        );
        return;
    }

    # call CreateTargetDBConnection on the specific backend
    my $TargetDBConnection = $Self->{$CloneDBBackend}->CreateTargetDBConnection(
        %{ $Param{TargetDBSettings} },
    );

    return $TargetDBConnection;
}

=item DataTransfer()

transfers information from a source DB to the Target DB.

    my $Success = $BackendObject->DataTransfer(
        TargetDBObject => $TargetDBObject, # mandatory
    );

=cut

sub DataTransfer {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TargetDBObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    # set the source db specific backend
    my $SourceDBBackend = 'CloneDB' . $Kernel::OM->Get('Kernel::System::DB')->{'DB::Type'} . 'Object';

    if ( !$Self->{$SourceDBBackend} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Backend " . $Kernel::OM->Get('Kernel::System::DB')->{'DB::Type'} . " is invalid!"
        );
        return;
    }

    # set the target db specific backend
    my $TargetDBBackend = 'CloneDB' . $Param{TargetDBObject}->{'DB::Type'} . 'Object';

    if ( !$Self->{$TargetDBBackend} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Backend $Param{TargetDBObject}->{'DB::Type'} is invalid!"
        );
        return;
    }

    # call DataTransfer on the specific backend
    my $DataTransfer = $Self->{$SourceDBBackend}->DataTransfer(
        TargetDBObject  => $Param{TargetDBObject},
        TargetDBBackend => $Self->{$TargetDBBackend},
        DryRun          => $Param{DryRun},
        Force           => $Param{Force},
    );

    return $DataTransfer;
}

=item SanityChecks()

perform some sanity check befor db cloning.

    my $SuccessSanityChecks = $BackendObject->SanityChecks(
        TargetDBObject => $TargetDBObject, # mandatory
    );

=cut

sub SanityChecks {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TargetDBObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    # set the clone db specific backend
    my $CloneDBBackend = 'CloneDB' . $Kernel::OM->Get('Kernel::System::DB')->{'DB::Type'} . 'Object';

    if ( !$Self->{$CloneDBBackend} ) {
        $Kernel::OM->Get('Kernel::System::Log')->Log(
            Priority => 'error',
            Message  => "Backend " . $Kernel::OM->Get('Kernel::System::DB')->{'DB::Type'} . " is invalid!"
        );
        return;
    }

    # perform sanity checks
    my $SanityChecks = $Self->{$CloneDBBackend}->SanityChecks(
        TargetDBObject => $Param{TargetDBObject},
        DryRun         => $Param{DryRun},
        Force          => $Param{Force},
    );

    return $SanityChecks;
}

sub _GenerateTargetStructuresSQL {
    my ( $Self, %Param ) = @_;

    for my $Needed (qw(TargetDBObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    $Self->PrintWithTime("Generating DDL for OTRS.\n");

    # SourceDBObject get data
    my $PackageObject = $Kernel::OM->Get('Kernel::System::Package');
    my @Packages      = $PackageObject->RepositoryList();
    my $SQLDirectory  = $Kernel::OM->Get('Kernel::Config')->Get('Home') . '/scripts/database';

    # attension!!!
    # switch database object to target object to use the xml
    # object of the target database
    $Kernel::OM->ObjectsDiscard(
        Objects => [
            'Kernel::System::DB',
            'Kernel::System::XML',
        ],
    );
    $Kernel::OM->ObjectInstanceRegister(
        Package => 'Kernel::System::DB',
        Object  => $Param{TargetDBObject},
    );

    my $XMLObject = $Kernel::OM->Get('Kernel::System::XML');    # of target database

    if ( !-f "$SQLDirectory/otrs-schema.xml" ) {
        die "SQL directory $SQLDirectory not found.";
    }

    my $XML = $Kernel::OM->Get('Kernel::System::Main')->FileRead(
        Directory => $SQLDirectory,
        Filename  => 'otrs-schema.xml',
    );
    my @XMLArray = $XMLObject->XMLParse(
        String => $XML,
    );
    $Self->{SQL} = [];
    push @{ $Self->{SQL} }, $Param{TargetDBObject}->SQLProcessor(
        Database => \@XMLArray,
    );
    $Self->{SQLPost} = [];
    push @{ $Self->{SQLPost} }, $Param{TargetDBObject}->SQLProcessorPost();

    # first step: get the dependencies into a single hash,
    # so that the topological sorting goes faster
    my %ReverseDependencies;
    for my $Package (@Packages) {
        my $Dependencies = $Package->{PackageRequired} // [];

        for my $Dependency (@$Dependencies) {

            # undef happens to be the value that uses the least amount
            # of memory in Perl, and we are only interested in the keys
            $ReverseDependencies{ $Dependency->{Content} }->{ $Package->{Name}->{Content} } = undef;
        }
    }

    # second step: sort packages based on dependencies
    my $Sort = sub {
        if (
            exists $ReverseDependencies{ $a->{Name}->{Content} }
            && exists $ReverseDependencies{ $a->{Name}->{Content} }->{ $b->{Name}->{Content} }
            )
        {
            return -1;
        }
        if (
            exists $ReverseDependencies{ $b->{Name}->{Content} }
            && exists $ReverseDependencies{ $b->{Name}->{Content} }->{ $a->{Name}->{Content} }
            )
        {
            return 1;
        }
        return 0;
    };
    @Packages = sort { $Sort->() } @Packages;

    # loop all locally installed packages
    PACKAGE:
    for my $Package (@Packages) {
        $Self->PrintWithTime("Generating DDL for package $Package->{Name}->{Content}.\n");
        next PACKAGE if !$Package->{DatabaseInstall};

        TYPE:
        for my $Type (qw(pre post)) {
            next TYPE if !$Package->{DatabaseInstall}->{$Type};

            push @{ $Self->{SQL} }, $Param{TargetDBObject}->SQLProcessor(
                Database => $Package->{DatabaseInstall}->{$Type},
            );
            push @{ $Self->{SQLPost} }, $Param{TargetDBObject}->SQLProcessorPost();
        }
    }

    # discard objects of target database to switch back to source object
    $Kernel::OM->ObjectsDiscard(
        Objects => [
            'Kernel::System::DB',
            'Kernel::System::XML',
        ],
    );

    return;
}

sub PopulateTargetStructuresPre {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TargetDBObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    $Self->_GenerateTargetStructuresSQL(%Param);

    $Self->PrintWithTime("Creating structures in target database (phase 1/2)");

    STATEMENT:
    for my $Statement ( @{ $Self->{SQL} } ) {
        next STATEMENT if $Statement =~ m{^INSERT}smxi;
        my $Result = $Param{TargetDBObject}->Do( SQL => $Statement );
        print '.';
        if ( !$Result ) {
            die
                "ERROR: Could not generate structures in target database!\nPlease make sure the target database is empty.\n";
        }
    }

    print " done.\n";

    return 1;
}

sub PopulateTargetStructuresPost {
    my ( $Self, %Param ) = @_;

    # check needed stuff
    for my $Needed (qw(TargetDBObject)) {
        if ( !$Param{$Needed} ) {
            $Kernel::OM->Get('Kernel::System::Log')->Log(
                Priority => 'error',
                Message  => "Need $Needed!"
            );
            return;
        }
    }

    $Self->PrintWithTime("Creating structures in target database (phase 2/2)");

    for my $Statement ( @{ $Self->{SQLPost} } ) {
        next STATEMENT if $Statement =~ m{^INSERT}smxi;
        my $Result = $Param{TargetDBObject}->Do( SQL => $Statement );
        print '.';
        if ( !$Result ) {
            die "ERROR: Could not generate structures in target database!\n";
        }
    }

    print " done.\n";

    return 1;
}

sub PrintWithTime {
    my $Self = shift;

    my $TimeStamp = $Kernel::OM->Get('Kernel::System::Time')->SystemTime2TimeStamp(
        SystemTime => $Kernel::OM->Get('Kernel::System::Time')->SystemTime(),
    );

    print "[$TimeStamp] ", @_;
}

=back

=cut

1;

=head1 TERMS AND CONDITIONS

This software is part of the OTRS project (L<http://otrs.org/>).

This software comes with ABSOLUTELY NO WARRANTY. For details, see
the enclosed file COPYING for license information (AGPL). If you
did not receive this file, see L<http://www.gnu.org/licenses/agpl.txt>.

=cut
